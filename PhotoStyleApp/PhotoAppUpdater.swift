import AppKit
import OSLog

@MainActor
final class PhotoAppUpdater {
    static let repository = "VaderChen/FilmDevelop"
    private weak var coordinator: PhotoStyleWebCoordinator?
    private var task: Task<Void, Never>?
    private var didCheckAtLaunch = false
    private var checkingNetwork = false
    private var manualRequested = false
    private var progressAlert: NSAlert?
    private var progressBar: NSProgressIndicator?
    private var progressLabel: NSTextField?
    private var progressCancel: (() -> Void)?
    private var transferID: UUID?
    private var phase: PhotoAppUpdatePhase = .checking
    private static let logger = Logger(subsystem: "person.vader.PhotoStyleApp", category: "AppUpdate")
    private let session: URLSession
    private let currentVersion: PhotoAppVersion?
    private let launchDelay: UInt64
    private let isApplicationActive: @MainActor () -> Bool

    init(coordinator: PhotoStyleWebCoordinator, session: URLSession? = nil,
         currentVersion: PhotoAppVersion? = PhotoAppVersion.installed(), launchDelay: UInt64 = 3_000_000_000,
         isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.coordinator = coordinator
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 1800
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration)
        self.currentVersion = currentVersion
        self.launchDelay = launchDelay
        self.isApplicationActive = isApplicationActive
    }

    func checkAtLaunch() {
        guard !didCheckAtLaunch else { return }
        didCheckAtLaunch = true
        let confirmed = PhotoAppUpdateInstaller.finishInstallation(arguments: ProcessInfo.processInfo.arguments)
        if let currentVersion { Self.recordLaunch(version: currentVersion, installationConfirmed: confirmed) }
        check(manual: false)
    }

    func check(manual: Bool = true) {
        guard task == nil else {
            if manual {
                manualRequested = true
                if checkingNetwork, progressAlert == nil { showProgress(title: "正在檢查更新", detail: "正在連線至 GitHub…", cancellable: true) }
            }
            progressAlert?.window.makeKeyAndOrderFront(nil)
            return
        }
        checkingNetwork = false
        phase = .checking
        manualRequested = manual
        task = Task { [weak self] in
            guard let self else { return }
            defer { closeProgress(); transferID = nil; task = nil; checkingNetwork = false; manualRequested = false }
            do {
                if !manual { try await Task.sleep(nanoseconds: launchDelay) }
                try await presentUpdateNoticeIfNeeded()
                checkingNetwork = true
                guard let current = currentVersion else {
                    throw PhotoAppUpdateError(message: "無法辨識目前版本，請先安裝正式版本。")
                }
                if manualRequested, progressAlert == nil { showProgress(title: "正在檢查更新", detail: "正在連線至 GitHub…", cancellable: true) }
                let request = Self.request(URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
                let (data, response) = try await session.data(for: request, delegate: PhotoUpdateTransfer())
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw Self.connectionError }
                if response.statusCode == 404 {
                    throw PhotoAppUpdateError(message: "目前尚無可下載的公開版本。請確認 GitHub 儲存庫已公開，並已發布 Release。")
                }
                guard response.statusCode == 200 else {
                    throw PhotoAppUpdateError(message: response.statusCode == 403 || response.statusCode == 429
                        ? "GitHub 暫時限制查詢次數，請稍後再試。" : "無法取得 GitHub 最新版本，請稍後再試。")
                }
                let release = try JSONDecoder().decode(PhotoAppRelease.self, from: data)
                let update = try release.update(after: current, repository: Self.repository)
                checkingNetwork = false
                closeProgress()
                guard let (version, asset) = update else {
                    if manualRequested { _ = await alert("已是最新版本", "目前版本：\(current.display)", buttons: ["好"]) }
                    return
                }
                // A launch check stays quiet until the user returns and photo work is idle.
                while !readyToPresent {
                    try Task.checkCancellation()
                    guard coordinator?.isTerminating != true else { return }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                let answer = await alert("有新版本可更新", "目前：\(current.display)\n新版：\(version.display)\n\n下載完成後會保存照片調整、更新 App 並重新開啟。",
                                         buttons: ["下載並更新", "稍後"])
                guard answer == .alertFirstButtonReturn else { return }
                try Task.checkCancellation()
                try await downloadAndInstall(asset: asset, version: version)
            } catch {
                closeProgress()
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                let failure = error as NSError
                Self.logger.error("Update failed: phase=\(self.phase.title, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                // Startup network errors and missing releases do not interrupt editing.
                if manualRequested || transferID != nil {
                    let message = PhotoAppUpdateError.explanation(for: error, phase: phase)
                    _ = await alert("更新未完成", message, buttons: ["好"])
                }
            }
        }
    }

    static let lastLaunchedVersionKey = "appUpdate.lastLaunchedVersion.v1"
    static let pendingNoticeKey = "appUpdate.pendingNotice.v1"
    static let acknowledgedNoticeKey = "appUpdate.acknowledgedNotice.v1"

    static func recordLaunch(version: PhotoAppVersion, installationConfirmed: Bool,
                             defaults: UserDefaults = .standard) {
        let previous = defaults.string(forKey: lastLaunchedVersionKey).flatMap { PhotoAppVersion(tag: $0) }
        if (installationConfirmed || previous.map { version > $0 } == true),
           defaults.string(forKey: acknowledgedNoticeKey) != version.tag {
            defaults.set(version.tag, forKey: pendingNoticeKey)
        }
        defaults.set(version.tag, forKey: lastLaunchedVersionKey)
    }

    // Bundled with this release so the notice is available without a network request.
    static let releaseHighlights = [
        "數位曝光下方新增鮮豔度與飽和度，可分別調整色彩。",
        "調整明暗時更能保留原有色彩，減少偏色與色彩過度放大。",

        "裁切第一次拖曳就能調整，不必再拖第二次。",
        "切換底片不會清除裁切與修復；切到未編輯照片時會顯示原片。",
        "各款底片與掃描風格更容易分辨，新增五款掃描設備模擬。",
        "可選擇顯示更多同系列底片，底片清單也能收合。"
    ]

    private func presentUpdateNoticeIfNeeded() async throws {
        guard let currentVersion,
              UserDefaults.standard.string(forKey: Self.pendingNoticeKey) == currentVersion.tag,
              UserDefaults.standard.string(forKey: Self.acknowledgedNoticeKey) != currentVersion.tag else { return }
        while !readyToPresent {
            try Task.checkCancellation()
            guard coordinator?.isTerminating != true else { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        _ = await alert("更新完成", "目前版本：\(currentVersion.display)", buttons: ["好"],
                        bullets: Self.releaseHighlights)
        UserDefaults.standard.set(currentVersion.tag, forKey: Self.acknowledgedNoticeKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingNoticeKey)
    }

    private var readyToPresent: Bool {
        guard let coordinator, !coordinator.isTerminating else { return false }
        return isApplicationActive() && coordinator.isWebReady && !coordinator.isLoadingImage && !coordinator.isSavingImage
            && !coordinator.isComputing && !coordinator.isMCPMutating && !coordinator.aiModelStore.isBusy
            && coordinator.webView?.window?.attachedSheet == nil
    }

    static var connectionError: PhotoAppUpdateError { PhotoAppUpdateError(message: "無法連線至 GitHub，請稍後再試。") }

    static func request(_ url: URL, download: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(download ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FilmYourPhoto-Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func downloadAndInstall(asset: PhotoAppRelease.Asset, version: PhotoAppVersion) async throws {
        phase = .preparing
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        try PhotoAppUpdateInstaller.validateDestination(target)
        guard let helper = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "Updater") else {
            throw PhotoAppUpdateError(message: "找不到更新工具，請重新安裝 App。")
        }
        let id = UUID()
        transferID = id
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(PhotoAppUpdateInstaller.workPrefix + id.uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared: PhotoAppPreparedUpdate?
        var handedOff = false
        defer {
            if !handedOff {
                prepared?.discard()
                try? fm.removeItem(at: work)
            }
        }
        phase = .downloading
        showProgress(title: "正在下載更新", detail: version.display, cancellable: true)
        isDownloadingUpdate = true
        let transfer = PhotoUpdateTransfer { [weak self] completed, expected in
            Task { @MainActor in
                guard let self, self.transferID == id else { return }
                self.showDownloadProgress(completed: completed, total: expected > 0 ? expected : asset.size)
            }
        }
        let dmg = work.appendingPathComponent("update.dmg")
        let response = try await transfer.download(Self.request(asset.url, download: true), to: dmg)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw Self.connectionError }
        isDownloadingUpdate = false
        phase = .preparing
        progressAlert?.messageText = PhotoL10n.text("正在準備更新")
        progressAlert?.buttons.first?.isEnabled = false
        progressLabel?.stringValue = PhotoL10n.text("正在驗證安裝檔，完成後會重新開啟 App…")
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        let result = try await Task.detached(priority: .userInitiated) {
            try PhotoAppUpdateInstaller.prepare(dmg: dmg, asset: asset, version: version, target: target, work: work, helper: helper)
        }.value
        prepared = result
        try Task.checkCancellation()
        guard let coordinator, !coordinator.isTerminating,
              !coordinator.isSavingImage, !coordinator.isComputing, !coordinator.isMCPMutating else {
            throw PhotoAppUpdateError(message: "照片仍在處理中，請完成後再更新。")
        }
        phase = .installing
        // Use the app's existing termination delegate to persist edits and drain GPU work.
        coordinator.commitAdjustmentPreview()
        coordinator.persistCurrentPhotoEdits()
        await coordinator.waitForSourcePersistence()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [work.appendingPathComponent("install.sh").path, String(ProcessInfo.processInfo.processIdentifier),
                             target.path, result.staged.path, result.backup.path, work.path,
                             PhotoL10n.text("更新未完成"), PhotoL10n.text("已保留原本的 App，請重新開啟後再試一次。"),
                             PhotoL10n.text("更新已安裝"), PhotoL10n.text("尚未確認新版已開啟。請手動開啟 App；舊版備份仍保留。")]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        handedOff = true
        closeProgress()
        PhotoStyleApplicationDelegate.terminateAfterUpdate()
    }

    private var isDownloadingUpdate = false

    private func showDownloadProgress(completed: Int64, total: Int64) {
        guard isDownloadingUpdate,
              let progressBar, let progressLabel, total > 0 else { return }
        progressBar.isIndeterminate = false
        let fraction = min(1, max(0, Double(completed) / Double(total)))
        progressBar.doubleValue = fraction * 100
        let bytes = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        progressLabel.stringValue = "\(Int(fraction * 100))% · \(bytes) / \(size)"
    }

    private func showProgress(title: String, detail: String, cancellable: Bool) {
        closeProgress()
        let dialog = NSAlert()
        dialog.messageText = PhotoL10n.text(title)
        dialog.informativeText = PhotoL10n.text("請保持網路連線。")
        dialog.addButton(withTitle: PhotoL10n.text("取消"))
        dialog.buttons[0].isEnabled = cancellable
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 54))
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 30, width: 360, height: 14))
        bar.style = .bar; bar.isIndeterminate = true; bar.minValue = 0; bar.maxValue = 100; bar.startAnimation(nil)
        let label = NSTextField(labelWithString: PhotoL10n.text(detail))
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        view.addSubview(bar); view.addSubview(label)
        dialog.accessoryView = view
        progressAlert = dialog; progressBar = bar; progressLabel = label
        progressCancel = { [weak self] in self?.task?.cancel() }
        if let window = coordinator?.webView?.window ?? NSApp.mainWindow {
            dialog.beginSheetModal(for: window) { [weak self, weak dialog] _ in
                guard let self, let dialog, self.progressAlert === dialog else { return }
                self.progressCancel?()
            }
        } else {
            closeProgress()
        }
    }

    private func closeProgress() {
        isDownloadingUpdate = false
        let dialog = progressAlert
        progressAlert = nil; progressBar = nil; progressLabel = nil; progressCancel = nil
        if let window = dialog?.window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
    }

    private func alert(_ title: String, _ detail: String, buttons: [String], bullets: [String] = []) async -> NSApplication.ModalResponse {
        let dialog = NSAlert()
        dialog.messageText = PhotoL10n.text(title); dialog.informativeText = PhotoL10n.text(detail)
        buttons.forEach { dialog.addButton(withTitle: PhotoL10n.text($0)) }
        if !bullets.isEmpty {
            let screenWidth = coordinator?.webView?.window?.screen?.visibleFrame.width
                ?? NSScreen.main?.visibleFrame.width ?? 1024
            let width = min(760, max(280, screenWidth - 180))
            let label = NSTextField(wrappingLabelWithString: bullets.map { "• " + PhotoL10n.text($0) }.joined(separator: "\n\n"))
            label.font = .systemFont(ofSize: 13)
            label.preferredMaxLayoutWidth = width
            label.maximumNumberOfLines = 0
            let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 160)
            label.frame = NSRect(x: 0, y: 0, width: width, height: height + 8)
            dialog.accessoryView = label
        }
        if let window = coordinator?.webView?.window ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                dialog.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return dialog.runModal()
    }
}
