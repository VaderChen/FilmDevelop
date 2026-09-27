import AppKit
import CoreImage
import PhotoStyleShared
import OSLog
import UniformTypeIdentifiers

struct PhotoBatchExportProgress {
    let id = UUID().uuidString
    let total: Int
    var index = 0
    var succeeded = 0
    var failed = 0
    var filename = ""
    var stage = "準備輸出"
    var fraction = 0.0

    var payload: [String: Any] {
        ["id": id, "total": total, "current": index + 1, "succeeded": succeeded,
         "failed": failed, "filename": filename, "stage": stage,
         "progress": min(1, (Double(index) + fraction) / Double(max(1, total)))]
    }
}

extension PhotoStyleWebCoordinator {
    func chooseExportDirectory() {
        guard !isTerminating, let window = webView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoL10n.text("預設輸出目錄")
        panel.prompt = PhotoL10n.text("選擇目錄")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let initialURL = exportDirectoryPreference.directoryURL()
        let scoped = initialURL?.startAccessingSecurityScopedResource() ?? false
        panel.directoryURL = initialURL
        panel.beginSheetModal(for: window) { [weak self] response in
            defer { if scoped { initialURL?.stopAccessingSecurityScopedResource() } }
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.exportDirectoryPreference.setDirectory(url)
                self.sendState(includeImages: false)
            } catch {
                self.sendToast("無法記住輸出目錄：\(error.localizedDescription)")
            }
        }
    }

    func chooseThumbnailExportDirectory(urls: [URL]) {
        guard !urls.isEmpty, canImport, let window = webView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoL10n.text("輸出")
        panel.prompt = PhotoL10n.text("選擇目錄")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let initialURL = exportDirectoryPreference.directoryURL()
        let scoped = initialURL?.startAccessingSecurityScopedResource() ?? false
        panel.directoryURL = initialURL
        // The same format/depth controls as single-photo export, without filename filtering.
        let format = PhotoExportFormatAccessory(panel: nil)
        panel.accessoryView = format.view
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [weak self, format] response in
            guard response == .OK, let directory = panel.url, let self, self.canImport else {
                if scoped { initialURL?.stopAccessingSecurityScopedResource() }
                return
            }
            Task { @MainActor in
                defer { if scoped { initialURL?.stopAccessingSecurityScopedResource() } }
                await self.exportThumbnailPhotos(urls, to: directory, format: format.selectedFormat,
                                                 bitDepth: format.selectedBitDepth)
            }
        }
    }

    @MainActor
    func exportThumbnailPhotos(_ urls: [URL], to directory: URL, format: PhotoExportFormat, bitDepth: Int) async {
        guard canImport, !urls.isEmpty else { return }
        commitAdjustmentPreview()
        persistCurrentPhotoEdits()
        isSavingImage = true
        batchExportProgress = PhotoBatchExportProgress(total: urls.count)
        let batchID = batchExportProgress!.id
        let access = directory.startAccessingSecurityScopedResource()
        defer {
            if access { directory.stopAccessingSecurityScopedResource() }
            exportWorker = nil
            batchExportProgress = nil
            isSavingImage = false
            savingStep = ""
            sendState(includeImages: false)
        }
        var completed = 0
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            if isTerminating || Task.isCancelled { break }
            batchExportProgress?.index = index
            batchExportProgress?.filename = url.lastPathComponent
            batchExportProgress?.stage = "正在讀取圖片"
            batchExportProgress?.fraction = 0
            let report: @Sendable (String, Double) -> Void = { [weak self] stage, fraction in
                DispatchQueue.main.async { [weak self] in
                    self?.updateBatchExportProgress(id: batchID, index: index, stage: stage, fraction: fraction)
                }
            }
            updateSavingStep("輸出 \(index + 1)／\(urls.count)：\(url.lastPathComponent)")
            let sourceAccess = url.startAccessingSecurityScopedResource()
            defer { if sourceAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let image: PhotoImage
                let style: PhotoStyle
                let adjustment: StyleAdjustment
                let patches: [PhotoRepairPatch]
                let fallbackMask: CIImage?
                if url == sourceFileURL, let current = sourceImage {
                    image = current
                    style = selectedStyle
                    adjustment = renderingAdjustment(adjustmentStore.adjustment(for: style))
                    patches = repairPatches
                    fallbackMask = sourceSubjectMask
                } else {
                    let decoded: (PhotoImage, String) = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async { [self] in
                            do {
                                let data = try Data(contentsOf: url)
                                guard let image = decodePickedImage(data: data, url: url) else {
                                    throw PhotoStyleWebSaveError.imageEncodingFailed
                                }
                                continuation.resume(returning: (image, Self.sourceImageIdentifier(for: data)))
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    image = decoded.0
                    let loaded = await photoEditStore.load(identifier: decoded.1, url: url, maskSize: image.size)
                    let record = photoEditStore.shouldRestoreEdits(loaded.record, at: url) ? loaded.record : nil
                    style = record.flatMap { PhotoStyle(rawValue: $0.selectedStyle) } ?? .original
                    adjustment = renderingAdjustment(record?.adjustments[style.rawValue]?.clamped() ?? .default(for: style))
                    patches = record?.repairPatches ?? []
                    fallbackMask = loaded.mask
                }
                if isTerminating || Task.isCancelled { break }
                let base = url.deletingLastPathComponent().lastPathComponent + " " + url.deletingPathExtension().lastPathComponent
                let suffix = format.fileExtensions[0]
                var destination = directory.appendingPathComponent(base + "." + suffix)
                var number = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = directory.appendingPathComponent("\(base) (\(number)).\(suffix)")
                    number += 1
                }
                let outputURL = destination
                let worker = Task.detached(priority: .userInitiated) { [renderer] () throws -> CGSize in
                    try Task.checkCancellation()
                    report("正在偵測主體遮罩", 0.1)
                    let needsMask = fallbackMask != nil || adjustment.requiresSubjectMask
                    let mask = needsMask && renderer.canDetectSubjectMask
                        ? renderer.detectSubjectMask(for: PhotoStyleProcessor.repairedSource(image, patches: patches)) : nil
                    report("正在處理照片", 0.15)
                    let output = autoreleasepool {
                        renderer.render(.init(style: style, adjustment: adjustment, image: image,
                            subjectMask: mask ?? fallbackMask, shouldDetectSubjectMask: false, repairPatches: patches,
                            progress: { report("正在處理照片", 0.15 + min(1, max(0, $0)) * 0.65) }))
                    }
                    try Task.checkCancellation()
                    report("正在編碼照片", 0.8)
                    guard let data = autoreleasepool(invoking: { output.encodedData(format: format, bitDepth: bitDepth, quality: 0.95) }) else {
                        throw PhotoStyleWebSaveError.imageEncodingFailed
                    }
                    try Task.checkCancellation()
                    report("正在儲存照片", 0.95)
                    try data.write(to: outputURL, options: .withoutOverwriting)
                    return output.size
                }
                exportWorker = worker
                _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                exportWorker = nil
                lastExportedPath = outputURL.path
                completed += 1
            } catch is CancellationError { break }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            batchExportProgress?.succeeded = completed
            batchExportProgress?.failed = failures.count
            updateBatchExportProgress(id: batchID, index: index, stage: "輸出完成", fraction: 1)
        }
        if !isTerminating {
            sendToast("已輸出 \(completed)／\(urls.count) 張照片。" + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n")))
        }
    }

    func updateBatchExportProgress(id: String, index: Int, stage: String, fraction: Double) {
        guard isSavingImage, var progress = batchExportProgress,
              progress.id == id, progress.index == index, fraction.isFinite else { return }
        let fraction = min(1, max(0, fraction))
        // Ignore late worker callbacks and coalesce render updates without repainting the editor.
        guard fraction >= progress.fraction,
              fraction - progress.fraction >= 0.01 || stage != progress.stage else { return }
        progress.stage = stage
        progress.fraction = fraction
        batchExportProgress = progress
        callJavaScript(function: "handleBatchExportProgress", payload: progress.payload)
    }

    func requestImageExport() {
        guard canExport else { return }
        if isWebReady, webView != nil {
            showPage("exportImage")
        } else {
            saveOutputImage()
        }
    }

    func saveOutputImageWhenReady() {
        guard let image = sourceImage?.cgImage else { return }
        let style = selectedStyle
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Committing a queued slider/crop edit may have just started a preview.
            // Do not lose the export command merely because that preview is busy.
            await self.waitForPreviewRender()
            guard self.sourceImage?.cgImage === image, self.selectedStyle == style else { return }
            self.saveOutputImage()
        }
    }

    func saveOutputImage() {
        guard canExport, sourceImage != nil, let window = webView?.window,
              window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        let initialURL = exportDirectoryPreference.directoryURL()
        let scoped = initialURL?.startAccessingSecurityScopedResource() ?? false
        panel.directoryURL = initialURL
        panel.title = PhotoL10n.text("匯出照片")
        panel.prompt = PhotoL10n.text("匯出")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let baseName = sourceFileName.isEmpty ? "PhotoStyle" : (sourceFileName as NSString).deletingPathExtension
        let directoryName = sourceFileURL?.deletingLastPathComponent().lastPathComponent ?? ""
        let exportName = directoryName.isEmpty ? baseName : "\(directoryName) \(baseName)"
        panel.nameFieldStringValue = "\(exportName).png"
        let format = PhotoExportFormatAccessory(panel: panel)
        panel.accessoryView = format.view
        panel.beginSheetModal(for: window) { [weak self, format] response in
            guard response == .OK, let url = panel.url, let self else {
                if scoped { initialURL?.stopAccessingSecurityScopedResource() }
                return
            }
            Task { @MainActor in
                // Keep the directory grant until the asynchronous write finishes.
                defer { if scoped { initialURL?.stopAccessingSecurityScopedResource() } }

                do {
                    _ = try await self.exportImage(to: url, format: format.selectedFormat,
                                                   bitDepth: format.selectedBitDepth, overwrite: true)
                }
                catch { self.sendToast("匯出失敗：\(error.localizedDescription)") }
            }
        }
    }

    @MainActor
    @discardableResult
    func exportImage(to url: URL, usesPNG: Bool, overwrite: Bool) async throws -> CGSize {
        let format: PhotoExportFormat = usesPNG ? .png : .jpeg
        return try await exportImage(to: url, format: format, bitDepth: format.defaultBitDepth, overwrite: overwrite)
    }

    @MainActor
    @discardableResult
    func exportImage(to url: URL, format: PhotoExportFormat, bitDepth: Int, overwrite: Bool) async throws -> CGSize {
        try Task.checkCancellation()
        guard format.supportedBitDepths.contains(bitDepth) else {
            throw PhotoStyleMCPTools.failure("\(format.displayName) 不支援 \(bitDepth) bit 匯出；可用色深為 \(format.supportedBitDepths.map(String.init).joined(separator: "、")) bit。")
        }
        guard let sourceImage, !isTerminating, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage else {
            throw PhotoStyleMCPTools.failure("目前沒有可匯出的照片，或影像仍在處理中。")
        }
        if !overwrite && FileManager.default.fileExists(atPath: url.path) {
            throw PhotoStyleMCPTools.failure("輸出檔案已存在；若要覆寫，請指定 overwrite: true。")
        }
        let style = selectedStyle
        let patches = repairPatches
        let adjustment = renderingAdjustment(adjustmentStore.adjustment(for: style))
        let fallbackSubjectMask = sourceSubjectMask
        let shouldUseSubjectMask = sourceSubjectMask != nil || adjustment.requiresSubjectMask
        let animationID = UUID().uuidString
        // The committed editor preview is already capped at 2048 px. Reuse it
        // throughout the animation; never decode/re-render the full export for it.
        let animationPreview = previewImagePayload["outputImage"] as? String
        let startedAt = ProcessInfo.processInfo.systemUptime
        let outputSize = PhotoStyleProcessor.renderedOutputSize(for: sourceImage.size, adjustment: adjustment)
        let sourcePixels = sourceImage.size.width * sourceImage.size.height
        let outputPixels = outputSize.width * outputSize.height
        // Similar processing/format combinations learn their own per-pixel duration.
        let profile = [style.rawValue, format.rawValue, String(bitDepth), String(shouldUseSubjectMask),
                       String(adjustment.backgroundBlur > 0), String(adjustment.denoise > 0),
                       String(adjustment.hdrAmount > 0), String(adjustment.filmEffects.scannerProfile.rawValue)].joined(separator: ":")
        let workUnits = max(0.25, (sourcePixels + outputPixels * CGFloat(bitDepth) / 8) / 1_000_000)
        let reportStage: @Sendable (String, Double) -> Void = { [weak self] stage, fraction in
            DispatchQueue.main.async { [weak self] in
                self?.callJavaScript(function: "handleExportDevelopment", payload: [
                    "phase": "progress", "id": animationID, "stage": stage, "progress": fraction
                ])
            }
        }
        isSavingImage = true
        callJavaScript(function: "handleExportDevelopment", payload: [
            "phase": "begin", "id": animationID, "image": animationPreview as Any? ?? NSNull(), "timing": ["profile": profile, "workUnits": workUnits]
        ])
        updateSavingStep("以原始解析度輸出")
        do {
            let worker = Task.detached(priority: .userInitiated) { [renderer] () throws -> CGSize in
                let logger = Logger(subsystem: "person.vader.PhotoStyleApp", category: "ExportTiming")
                var stageStart = ProcessInfo.processInfo.systemUptime
                func recordTiming(_ stage: String) {
                    let elapsed = ProcessInfo.processInfo.systemUptime - stageStart
                    logger.info("Export stage \(stage, privacy: .public): \(elapsed, privacy: .public) seconds")
                    stageStart = ProcessInfo.processInfo.systemUptime
                }
                try Task.checkCancellation()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let detectedMask = shouldUseSubjectMask && renderer.canDetectSubjectMask
                    ? renderer.detectSubjectMask(for: PhotoStyleProcessor.repairedSource(sourceImage, patches: patches)) : nil
                // 完整解析度重新辨識失敗時，仍沿用這張照片已確認的遮罩。
                let mask = detectedMask ?? fallbackSubjectMask
                try Task.checkCancellation()
                recordTiming("subject-mask")
                reportStage("render", 0)
                let output = autoreleasepool {
                    renderer.render(.init(style: style, adjustment: adjustment, image: sourceImage,
                        subjectMask: mask, shouldDetectSubjectMask: false, repairPatches: patches,
                        progress: { reportStage("render", $0) }))
                }
                try Task.checkCancellation()
                recordTiming("render")
                reportStage("encode", 0)
                guard let data = autoreleasepool(invoking: { output.encodedData(format: format, bitDepth: bitDepth, quality: 0.95) }) else {
                    throw PhotoStyleWebSaveError.imageEncodingFailed
                }
                try Task.checkCancellation()
                recordTiming("encode")
                reportStage("write", 0)
                try data.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
                recordTiming("write")
                return output.size
            }
            exportWorker = worker
            defer { exportWorker = nil }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            lastExportedPath = url.path
            callJavaScript(function: "handleExportDevelopment", payload: [
                "phase": "complete", "id": animationID,
                "durationMs": (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            ])
            finishSavingImage(message: "已匯出：\(url.lastPathComponent)")
            return result
        } catch {
            callJavaScript(function: "handleExportDevelopment", payload: ["phase": "cancel", "id": animationID])
            isSavingImage = false
            savingStep = ""
            sendState(includeImages: false)
            throw error
        }
    }
}

// Bookmark access is acquired only while selecting/exporting, never for the
// entire app lifetime. The displayed path does not resolve or mount a volume.
final class PhotoExportDirectoryPreference {
    private static let pathKey = "defaultExportDirectory.path.v1"
    private static let bookmarkKey = "defaultExportDirectory.bookmark.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var path: String { defaults.string(forKey: Self.pathKey) ?? "" }

    func setDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(url.path, forKey: Self.pathKey)
    }

    func directoryURL() -> URL? {
        if let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale { try? setDirectory(url) }
                defaults.set(url.path, forKey: Self.pathKey)
                return url
            }
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
}

@MainActor
final class PhotoExportFormatAccessory: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 108))
    private let formatPicker = NSPopUpButton(frame: NSRect(x: 86, y: 69, width: 280, height: 26))
    private let depthPicker = NSPopUpButton(frame: NSRect(x: 86, y: 35, width: 280, height: 26))
    private let detailLabel = NSTextField(labelWithString: "")
    private weak var panel: NSSavePanel?
    private let defaults: UserDefaults
    private static let formatKey = "photoExportFormat.v1"
    private static let depthsKey = "photoExportBitDepths.v1"
    private static let png8DefaultKey = "photoExportPNG8Default.v1"
    private var rememberedDepths: [String: Int]
    private(set) var selectedFormat: PhotoExportFormat
    private(set) var selectedBitDepth: Int

    init(panel: NSSavePanel?, defaults: UserDefaults = .standard) {
        self.panel = panel
        self.defaults = defaults
        let format = defaults.string(forKey: Self.formatKey).flatMap(PhotoExportFormat.init(rawValue:)) ?? .png
        var depths = defaults.dictionary(forKey: Self.depthsKey) as? [String: Int] ?? [:]
        // Adopt the new PNG default once, including preferences saved by older versions.
        if !defaults.bool(forKey: Self.png8DefaultKey) {
            depths[PhotoExportFormat.png.rawValue] = 8
            defaults.set(depths, forKey: Self.depthsKey)
            defaults.set(true, forKey: Self.png8DefaultKey)
        }
        let savedDepth = depths[format.rawValue] ?? format.defaultBitDepth
        selectedFormat = format
        selectedBitDepth = format.supportedBitDepths.contains(savedDepth) ? savedDepth : format.defaultBitDepth
        rememberedDepths = depths
        super.init()
        for (title, y) in [("檔案格式", 74.0), ("色深", 40.0)] {
            let label = NSTextField(labelWithString: PhotoL10n.text(title))
            label.font = .systemFont(ofSize: 13)
            label.frame = NSRect(x: 8, y: y, width: 74, height: 18)
            view.addSubview(label)
        }
        for picker in [formatPicker, depthPicker] {
            picker.font = .systemFont(ofSize: 13)
            picker.bezelStyle = .rounded
            picker.target = self
            view.addSubview(picker)
        }
        formatPicker.addItems(withTitles: PhotoExportFormat.allCases.map { PhotoL10n.text($0.displayName) })
        formatPicker.selectItem(at: PhotoExportFormat.allCases.firstIndex(of: selectedFormat)!)
        formatPicker.action = #selector(changeFormat)
        formatPicker.identifier = NSUserInterfaceItemIdentifier("exportFormat")
        formatPicker.setAccessibilityLabel(PhotoL10n.text("匯出檔案格式"))
        depthPicker.action = #selector(changeBitDepth)
        depthPicker.identifier = NSUserInterfaceItemIdentifier("exportBitDepth")
        depthPicker.setAccessibilityLabel(PhotoL10n.text("匯出色深"))
        detailLabel.frame = NSRect(x: 8, y: 7, width: 358, height: 18)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        view.addSubview(detailLabel)
        updateControls()
    }

    @objc private func changeFormat() {
        let index = formatPicker.indexOfSelectedItem
        guard PhotoExportFormat.allCases.indices.contains(index) else { return }
        selectFormat(PhotoExportFormat.allCases[index])
    }

    @objc private func changeBitDepth() {
        guard let depth = depthPicker.selectedItem?.tag else { return }
        selectBitDepth(depth)
    }

    func selectFormat(_ format: PhotoExportFormat) {
        rememberedDepths[selectedFormat.rawValue] = selectedBitDepth
        let preferred = rememberedDepths[format.rawValue] ?? selectedBitDepth
        selectedFormat = format
        selectedBitDepth = format.supportedBitDepths.contains(preferred) ? preferred : format.defaultBitDepth
        persistSelection()
        updateControls()
    }

    func selectBitDepth(_ bitDepth: Int) {
        guard selectedFormat.supportedBitDepths.contains(bitDepth) else { return }
        selectedBitDepth = bitDepth
        persistSelection()
        updateControls()
    }

    private func persistSelection() {
        rememberedDepths[selectedFormat.rawValue] = selectedBitDepth
        defaults.set(selectedFormat.rawValue, forKey: Self.formatKey)
        defaults.set(rememberedDepths, forKey: Self.depthsKey)
    }

    private func updateControls() {
        formatPicker.selectItem(at: PhotoExportFormat.allCases.firstIndex(of: selectedFormat)!)
        depthPicker.removeAllItems()
        for depth in selectedFormat.supportedBitDepths {
            depthPicker.addItem(withTitle: PhotoL10n.text(depth == 16 ? "16 bit／色彩通道" : "8 bit／色彩通道"))
            depthPicker.lastItem?.tag = depth
        }
        depthPicker.selectItem(withTag: selectedBitDepth)
        depthPicker.isEnabled = selectedFormat.supportedBitDepths.count > 1
        detailLabel.stringValue = PhotoL10n.text(selectedFormat.supportedBitDepths.count == 1
            ? "\(selectedFormat.displayName) 僅支援 8 bit；16 bit 請選 PNG 或 TIFF。"
            : "16 bit 保留細緻色階；8 bit 適合一般分享。")
        guard let panel else { return }
        panel.allowedContentTypes = [selectedFormat.contentType]
        let currentExtension = (panel.nameFieldStringValue as NSString).pathExtension.lowercased()
        if !selectedFormat.fileExtensions.contains(currentExtension) {
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension
                + "." + selectedFormat.fileExtensions[0]
        }
    }
}
