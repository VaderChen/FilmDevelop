import Foundation
import SwiftUI

struct AIRemoteFile: Hashable {
    let fileName: String
    let remoteURL: URL
}

struct AIModelBinding: Codable, Hashable {
    let mainFileName: String
    let family: String
    let auxiliaryFileName: String?
}

struct AIPresetModel: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let meta: String
    let pageURL: URL
    let binding: AIModelBinding
    let mainFile: AIRemoteFile
    let auxiliaryFiles: [AIRemoteFile]
}

struct AIModelStatus: Equatable {
    var ready: Bool
    var status: String
    var message: String
    var modelDirectory: URL
    var activeModelFileName: String
    var modelFiles: [String]
    var family: String
    var auxiliaryFileName: String?

    static let empty = AIModelStatus(
        ready: false,
        status: "model_missing",
        message: "尚未載入任何模型。",
        modelDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStyleApp", isDirectory: true)
            .appendingPathComponent("GGUFModels", isDirectory: true),
        activeModelFileName: "",
        modelFiles: [],
        family: "",
        auxiliaryFileName: nil
    )
}

struct AIDownloadProgress: Equatable {
    var active: Bool = false
    var fileName: String = ""
    var completedFiles: Int = 0
    var totalFiles: Int = 0
    var fraction: Double = 0
    var percent: Int = 0
}

struct AIImportProgress: Equatable {
    var active: Bool = false
    var fileName: String = ""
    var completedFiles: Int = 0
    var totalFiles: Int = 0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var isCancelling: Bool = false

    var fraction: Double {
        if totalBytes > 0 { return min(max(Double(completedBytes) / Double(totalBytes), 0), 1) }
        return totalFiles > 0 && completedFiles == totalFiles ? 1 : 0
    }
    var percent: Int { Int(round(fraction * 100)) }
}

/// Cancellation is requested by the main thread and observed between copy chunks.
/// The model-store busy gate stays held until the worker has removed its staging files.
private final class AIModelImportOperation {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { throw AIModelError.importCancelled }
    }
}

enum AIModelError: LocalizedError {
    case invalidURL(String)
    case downloadCancelled
    case importCancelled
    case modelMissing(String)
    case invalidModelFile(String)
    case auxiliaryMissing(String)
    case downloadFailed(Int)
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "無效的模型下載網址：\(value)"
        case .downloadCancelled:
            "模型下載已取消"
        case .importCancelled:
            "模型匯入已取消"
        case .modelMissing(let directory):
            "尚未安裝可用模型。模型目錄：\(directory)"
        case .invalidModelFile(let fileName):
            "\(fileName) 不是有效的 GGUF 模型檔"
        case .auxiliaryMissing(let directory):
            "找不到 mmproj 檔案。請同時選取主模型與 mmproj，或確認同一個資料夾內有 mmproj GGUF 檔：\(directory)"
        case .downloadFailed(let status):
            "模型下載失敗（HTTP \(status)）"
        case .busy:
            "模型匯入、下載或目錄掃描正在進行中"
        }
    }
}

/// Stage every file before replacing a model pair. A failed copy must not destroy
/// the installed model, including when the selected source is the installed file.
enum AIModelFileOperations {
    static func validateGGUF(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AIModelError.invalidModelFile(url.lastPathComponent)
        }
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 24), header.count == 24,
              header.prefix(4) == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw AIModelError.invalidModelFile(url.lastPathComponent)
        }
        let version = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
        guard version == 2 || version == 3 else {
            throw AIModelError.invalidModelFile(url.lastPathComponent)
        }
    }

    static func install(
        _ files: [(source: URL, destination: URL)],
        progress: ((AIImportProgress) -> Void)? = nil,
        checkCancellation: () throws -> Void = {}
    ) throws {
        let manager = FileManager.default
        try checkCancellation()
        for file in files { try validateGGUF(at: file.source) }
        let changed = files.filter {
            $0.source.resolvingSymlinksInPath().standardizedFileURL != $0.destination.resolvingSymlinksInPath().standardizedFileURL
        }
        guard let first = changed.first else {
            progress?(AIImportProgress(active: true, fileName: files.last?.source.lastPathComponent ?? "",
                                       completedFiles: files.count, totalFiles: files.count))
            return
        }
        let totalBytes = try changed.reduce(Int64(0)) { sum, file in
            sum + Int64(try file.source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        var copyProgress = AIImportProgress(active: true, totalFiles: changed.count, totalBytes: totalBytes)
        let staging = first.destination.deletingLastPathComponent()
            .appendingPathComponent(".model-install-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var backups: [(original: URL, backup: URL)] = []
        var installed: [URL] = []
        do {
            // Stage the whole pair before touching installed weights. Custom imports
            // copy bounded chunks so even multi-GB files remain cancellable.
            for (index, file) in changed.enumerated() {
                try checkCancellation()
                copyProgress.fileName = file.source.lastPathComponent
                progress?(copyProgress)
                let target = staging.appendingPathComponent("new-\(index)")
                if let progress {
                    try copyInChunks(from: file.source, to: target, checkCancellation: checkCancellation) { bytes in
                        copyProgress.completedBytes += Int64(bytes)
                        progress(copyProgress)
                    }
                } else {
                    try manager.copyItem(at: file.source, to: target)
                }
                try validateGGUF(at: target)
                copyProgress.completedFiles = index + 1
                progress?(copyProgress)
            }
            try checkCancellation()
            // Once replacement starts, finish or roll back the whole pair without
            // interruption. A late cancellation cannot leave half a model installed.
            for (index, file) in changed.enumerated() {
                if manager.fileExists(atPath: file.destination.path) {
                    let backup = staging.appendingPathComponent("old-\(index).bak")
                    try manager.moveItem(at: file.destination, to: backup)
                    backups.append((file.destination, backup))
                }
                try manager.moveItem(at: staging.appendingPathComponent("new-\(index)"), to: file.destination)
                installed.append(file.destination)
            }
        } catch {
            for destination in installed.reversed() { try? manager.removeItem(at: destination) }
            var restored = true
            for backup in backups.reversed() {
                do { try manager.moveItem(at: backup.backup, to: backup.original) }
                catch { restored = false }
            }
            // Retain a recovery copy if the filesystem prevents rollback.
            if restored { try? manager.removeItem(at: staging) }
            throw error
        }
        try? manager.removeItem(at: staging)
    }

    private static func copyInChunks(
        from source: URL, to destination: URL,
        checkCancellation: () throws -> Void,
        didCopy: (Int) -> Void
    ) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        while true {
            try checkCancellation()
            guard let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            didCopy(chunk.count)
        }
        try writer.synchronize()
    }
}

final class AIPresetDownloader: NSObject, URLSessionDownloadDelegate {
    private let files: [AIRemoteFile]
    private let destinationDirectory: URL
    private let progressHandler: (AIDownloadProgress) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private let workQueue = DispatchQueue(label: "person.vader.PhotoStyleApp.modelDownload", qos: .utility)

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.isDiscretionary = false
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = workQueue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var currentIndex = 0
    private var expectedBytes: [Int64]
    private var downloadedBytes: [Int64]
    private var stagingDirectory: URL?
    private var currentTask: URLSessionDownloadTask?
    private var isCancelled = false
    private var hasCompleted = false

    init(
        files: [AIRemoteFile],
        destinationDirectory: URL,
        progressHandler: @escaping (AIDownloadProgress) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.files = files
        self.destinationDirectory = destinationDirectory
        self.progressHandler = progressHandler
        self.completion = completion
        self.expectedBytes = Array(repeating: 0, count: files.count)
        self.downloadedBytes = Array(repeating: 0, count: files.count)
    }

    func start() {
        workQueue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !hasCompleted, currentTask == nil else { return }
        guard !files.isEmpty else {
            finish(.success(()))
            return
        }
        do {
            let staging = destinationDirectory.appendingPathComponent(".model-download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            stagingDirectory = staging
        } catch {
            finish(.failure(error))
            return
        }
        startCurrentDownload()
    }

    func cancel() {
        workQueue.async { self.cancelOnQueue() }
    }

    private func cancelOnQueue() {
        guard !hasCompleted else { return }
        isCancelled = true
        currentTask?.cancel()
        session.invalidateAndCancel()
        cleanupDownloadedFiles()
        finish(.failure(AIModelError.downloadCancelled))
    }

    private func startCurrentDownload() {
        guard currentIndex < files.count else {
            session.finishTasksAndInvalidate()
            finish(.success(()))
            return
        }

        let task = session.downloadTask(with: files[currentIndex].remoteURL)
        currentTask = task
        task.resume()
        emitProgress()
    }

    private func emitProgress() {
        guard !files.isEmpty else { return }
        let currentFile = files[min(currentIndex, files.count - 1)]
        let totalExpected = expectedBytes.reduce(0, +)
        let totalDownloaded = zip(downloadedBytes, expectedBytes).reduce(Int64(0)) { partial, pair in
            pair.1 > 0 ? partial + min(pair.0, pair.1) : partial + pair.0
        }

        let fraction: Double
        let hasUnknownPendingBytes = expectedBytes.enumerated().contains { index, expected in
            index >= currentIndex && expected <= 0
        }
        if totalExpected > 0 && !hasUnknownPendingBytes {
            fraction = min(max(Double(totalDownloaded) / Double(totalExpected), 0), 1)
        } else {
            let currentExpected = currentIndex < expectedBytes.count ? expectedBytes[currentIndex] : 0
            let currentDownloaded = currentIndex < downloadedBytes.count ? downloadedBytes[currentIndex] : 0
            let currentFraction = currentExpected > 0 ? min(max(Double(currentDownloaded) / Double(currentExpected), 0), 1) : 0.02
            fraction = min(max((Double(currentIndex) + currentFraction) / Double(max(files.count, 1)), 0), 1)
        }

        let completedFiles = currentIndex
        DispatchQueue.main.async {
            self.progressHandler(AIDownloadProgress(
                active: true,
                fileName: currentFile.fileName,
                completedFiles: completedFiles,
                totalFiles: self.files.count,
                fraction: fraction,
                percent: Int(round(fraction * 100))
            ))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard !hasCompleted, !isCancelled, downloadTask == currentTask,
              currentIndex < downloadedBytes.count else { return }
        downloadedBytes[currentIndex] = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            expectedBytes[currentIndex] = totalBytesExpectedToWrite
        }
        emitProgress()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !hasCompleted, !isCancelled, downloadTask == currentTask,
              currentIndex < files.count, let stagingDirectory else { return }
        let file = files[currentIndex]
        let destinationURL = stagingDirectory.appendingPathComponent(file.fileName)

        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw AIModelError.downloadFailed((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try AIModelFileOperations.validateGGUF(at: location)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            if expectedBytes[currentIndex] == 0 {
                let size = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                expectedBytes[currentIndex] = size
                downloadedBytes[currentIndex] = size
            }
        } catch {
            session.invalidateAndCancel()
            cleanupDownloadedFiles()
            finish(.failure(error))
            return
        }

        currentIndex += 1
        if currentIndex < files.count {
            startCurrentDownload()
        } else {
            do {
                try AIModelFileOperations.install(files.map {
                    (stagingDirectory.appendingPathComponent($0.fileName), destinationDirectory.appendingPathComponent($0.fileName))
                })
                cleanupDownloadedFiles()
                DispatchQueue.main.async {
                    self.progressHandler(AIDownloadProgress(
                        active: true,
                        fileName: file.fileName,
                        completedFiles: self.files.count,
                        totalFiles: self.files.count,
                        fraction: 1,
                        percent: 100
                    ))
                }
                finish(.success(()))
            } catch {
                cleanupDownloadedFiles()
                finish(.failure(error))
            }
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if isCancelled || hasCompleted { return }
        session.invalidateAndCancel()
        cleanupDownloadedFiles()
        finish(.failure(error))
    }

    private func cleanupDownloadedFiles() {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}

final class AIModelStore: ObservableObject {
    static let presets: [AIPresetModel] = [
        AIPresetModel(
            id: "qwen3Vl2bQ4km",
            title: "Qwen3-VL-2B",
            subtitle: "最均衡、推薦使用",
            meta: "Q4_K_M · 1.11 GB",
            pageURL: URL(string: "https://huggingface.co/unsloth/Qwen3-VL-2B-Instruct-GGUF")!,
            binding: AIModelBinding(mainFileName: "Qwen3-VL-2B-Instruct-Q4_K_M.gguf", family: "qwen3vl", auxiliaryFileName: "mmproj-F16.gguf"),
            mainFile: AIRemoteFile(fileName: "Qwen3-VL-2B-Instruct-Q4_K_M.gguf", remoteURL: URL(string: "https://huggingface.co/unsloth/Qwen3-VL-2B-Instruct-GGUF/resolve/main/Qwen3-VL-2B-Instruct-Q4_K_M.gguf?download=true")!),
            auxiliaryFiles: [
                AIRemoteFile(fileName: "mmproj-F16.gguf", remoteURL: URL(string: "https://huggingface.co/unsloth/Qwen3-VL-2B-Instruct-GGUF/resolve/main/mmproj-F16.gguf?download=true")!)
            ]
        ),
        AIPresetModel(
            id: "gemma4E2bQ4km",
            title: "Gemma 4 E2B",
            subtitle: "Gemma 4 · 輕量指令模型",
            meta: "Q4_K_M + mmproj Q8 · E2B",
            pageURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF")!,
            binding: AIModelBinding(mainFileName: "gemma-4-E2B-it-Q4_K_M.gguf", family: "gemma4", auxiliaryFileName: "gemma-4-E2B-it.mmproj-q8_0.gguf"),
            mainFile: AIRemoteFile(fileName: "gemma-4-E2B-it-Q4_K_M.gguf", remoteURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!),
            auxiliaryFiles: [
                AIRemoteFile(fileName: "gemma-4-E2B-it.mmproj-q8_0.gguf", remoteURL: URL(string: "https://huggingface.co/prithivMLmods/gemma-4-E2B-it-F32-GGUF/resolve/main/GGUF/gemma-4-E2B-it.mmproj-q8_0.gguf")!)
            ]
        ),
        AIPresetModel(
            id: "gemma4E4bQ4km",
            title: "Gemma 4 E4B",
            subtitle: "Gemma 4 · 指令模型",
            meta: "Q4_K_M + mmproj Q8 · E4B",
            pageURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF")!,
            binding: AIModelBinding(mainFileName: "gemma-4-E4B-it-Q4_K_M.gguf", family: "gemma4", auxiliaryFileName: "gemma-4-E4B-it.mmproj-q8_0.gguf"),
            mainFile: AIRemoteFile(fileName: "gemma-4-E4B-it-Q4_K_M.gguf", remoteURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!),
            auxiliaryFiles: [
                AIRemoteFile(fileName: "gemma-4-E4B-it.mmproj-q8_0.gguf", remoteURL: URL(string: "https://huggingface.co/prithivMLmods/gemma-4-E4B-it-F32-GGUF/resolve/main/GGUF/gemma-4-E4B-it.mmproj-q8_0.gguf")!)
            ]
        )
    ]

    let repositoryBrowser = AIRepositoryBrowser()

    @Published var status: AIModelStatus = .empty
    @Published var downloadProgress = AIDownloadProgress()
    @Published private(set) var importProgress = AIImportProgress()
    @Published private(set) var directoryCatalog = AIModelDirectoryCatalog()

    var isBusy: Bool { downloader != nil || repositoryDownloader != nil || importOperation != nil || directoryScanOperation != nil }
    var usingModelDirectory: Bool { selectedDirectoryModelID != nil }
    var selectedModelID: String {
        if let selectedDirectoryModelID { return "directory:" + selectedDirectoryModelID }
        return status.activeModelFileName.isEmpty ? "" : "installed:" + status.activeModelFileName
    }
    @Published var aiEnabled: Bool {
        didSet {
            catalogDefaults?.set(aiEnabled, forKey: aiEnabledKey)
        }
    }
    @Published var message: String?

    private let fileManager = FileManager.default
    private let modelDirectoryName = "GGUFModels"
    private let activeModelFileName = "active-model.txt"
    private let activeModelMetadataFileName = "active-model.json"
    private let aiEnabledKey = "photoStyle.ai.enabled"
    private let customModelDirectory: URL?
    private var downloader: AIPresetDownloader?
    private var repositoryDownloader: AIRepositoryDownloader?
    private var importOperation: AIModelImportOperation?
    private let importQueue = DispatchQueue(label: "person.vader.PhotoStyleApp.modelImport", qos: .utility)
    private let catalogDefaults: UserDefaults?
    private let catalogBookmarkKey = "photoStyle.ai.modelDirectory.bookmark"
    private let catalogPathKey = "photoStyle.ai.modelDirectory.path"
    private let catalogSelectionKey = "photoStyle.ai.modelDirectory.selectedModel"
    private var directoryAccess: AIModelDirectoryAccess?
    private var directoryScanOperation: AIModelDirectoryScanOperation?
    private var selectedDirectoryModelID: String?
    private var directoryRestoreError: String?
    private let directoryScanQueue = DispatchQueue(label: "person.vader.PhotoStyleApp.modelDirectoryScan", qos: .utility)

    init(modelDirectory: URL? = nil, catalogDefaults: UserDefaults? = nil) {
        precondition(Thread.isMainThread, "Create the observable model store on the main thread")
        self.customModelDirectory = modelDirectory
        // An injected managed directory is an isolated store unless persistence is explicitly supplied.
        self.catalogDefaults = catalogDefaults ?? (modelDirectory == nil ? .standard : nil)
        self.aiEnabled = self.catalogDefaults?.bool(forKey: aiEnabledKey) ?? false
        refreshStatus()
        restoreModelDirectory()
    }

    func selectModelDirectory(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        performOnMain {
            let isSameDirectory = self.directoryCatalog.directoryURL.map(AIModelDirectoryScanner.canonicalDirectoryURL)?.path
                == AIModelDirectoryScanner.canonicalDirectoryURL(url).path
            self.beginDirectoryScan(url, preferredID: isSameDirectory ? self.selectedDirectoryModelID : nil,
                                    activateFirst: !isSameDirectory || self.selectedDirectoryModelID == nil,
                                    completion: completion)
        }
    }

    func refreshModelDirectory() {
        performOnMain {
            guard let url = self.directoryAccess?.url ?? self.directoryCatalog.directoryURL else { return }
            self.beginDirectoryScan(url, preferredID: self.selectedDirectoryModelID, activateFirst: false) { _ in }
        }
    }

    func cancelModelDirectoryScan() {
        performOnMain { self.directoryScanOperation?.cancel() }
    }

    func selectModel(id: String) {
        performOnMain {
            guard !self.isBusy else { self.message = AIModelError.busy.localizedDescription; return }
            if id.hasPrefix("installed:") {
                self.performSetActiveModel(fileName: String(id.dropFirst("installed:".count)))
                return
            }
            guard id.hasPrefix("directory:"), let root = self.directoryCatalog.directoryURL,
                  let entry = self.directoryCatalog.models.first(where: { "directory:" + $0.id == id }) else {
                self.message = AIModelDirectoryError.invalidSelection.localizedDescription
                return
            }
            guard entry.ready else { self.message = entry.message; return }
            if entry.format == "mlx" {
                self.beginDirectoryScan(self.directoryAccess?.url ?? root, preferredID: entry.id, activateFirst: false) { _ in }
                return
            }
            do {
                _ = try AIModelDirectoryScanner.validate(entry: entry, root: root)
                self.selectedDirectoryModelID = entry.id
                self.directoryRestoreError = nil
                self.persistCatalogSelection()
                self.refreshStatusOnMain()
                self.message = "已切換模型：\(entry.title)"
            } catch { self.message = error.localizedDescription }
        }
    }

    private func beginDirectoryScan(_ url: URL, preferredID: String?, activateFirst: Bool,
                                    completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isBusy else {
            message = AIModelError.busy.localizedDescription
            completion(.failure(AIModelError.busy))
            return
        }
        let operation = AIModelDirectoryScanOperation(access: AIModelDirectoryAccess(url: url))
        directoryScanOperation = operation
        directoryCatalog.isScanning = true
        directoryCatalog.message = "正在掃描模型目錄…"
        directoryScanQueue.async {
            let result = Result { try AIModelDirectoryScanner.scan(root: url, checkCancellation: operation.checkCancellation) }
            DispatchQueue.main.async {
                // A cancellation arriving after the last directory entry still cancels the transaction.
                let completed = Result { () throws -> [AIModelDirectoryEntry] in
                    try operation.checkCancellation()
                    return try result.get()
                }
                self.directoryScanOperation = nil
                switch completed {
                case .success(let entries):
                    self.directoryAccess = operation.access
                    self.directoryRestoreError = nil
                    let readyCount = entries.filter(\.ready).count
                    let description = entries.isEmpty
                        ? "未找到 GGUF 主模型或 MLX 視覺模型；請確認所選目錄包含完整權重與設定檔。"
                        : "找到 \(entries.count) 個主模型，其中 \(readyCount) 個可使用。"
                    self.directoryCatalog = AIModelDirectoryCatalog(directoryURL: AIModelDirectoryScanner.canonicalDirectoryURL(url),
                                                                    message: description, models: entries)
                    self.selectedDirectoryModelID = preferredID ?? (activateFirst ? entries.first(where: \.ready)?.id : nil)
                    self.persistCatalogDirectory(url)
                    self.persistCatalogSelection()
                    self.refreshStatusOnMain()
                    self.message = description
                    completion(.success(()))
                case .failure(let error):
                    self.directoryCatalog.isScanning = false
                    self.directoryCatalog.message = error.localizedDescription
                    self.message = error.localizedDescription
                    if self.usingModelDirectory { self.refreshStatusOnMain() }
                    completion(.failure(error))
                }
            }
        }
    }

    private func restoreModelDirectory() {
        guard let catalogDefaults else { return }
        let data = catalogDefaults.data(forKey: catalogBookmarkKey)
        let selected = catalogDefaults.string(forKey: catalogSelectionKey) ?? ""
        let preferredID = selected.hasPrefix("directory:") ? String(selected.dropFirst("directory:".count)) : nil
        guard data != nil || preferredID != nil else { return }
        if let path = catalogDefaults.string(forKey: catalogPathKey), path.hasPrefix("/") {
            directoryCatalog.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let preferredID {
            let validationRoot = directoryCatalog.directoryURL ?? URL(fileURLWithPath: "/")
            if (try? AIModelDirectoryScanner.modelURL(id: preferredID, root: validationRoot)) != nil {
                selectedDirectoryModelID = preferredID
                directoryRestoreError = "正在還原先前選擇的模型目錄；完成前無法分析。"
                refreshStatusOnMain()
            }
        }
        do {
            guard let data else { throw AIModelDirectoryError.invalidDirectory }
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // Accept only a safe relative identifier before trying to restore an external selection.
            let safeID = preferredID.flatMap { (try? AIModelDirectoryScanner.modelURL(id: $0, root: url)) == nil ? nil : $0 }
            directoryCatalog.directoryURL = AIModelDirectoryScanner.canonicalDirectoryURL(url)
            beginDirectoryScan(url, preferredID: safeID, activateFirst: false) { result in
                if case .failure(let error) = result {
                    self.directoryRestoreError = "無法還原模型目錄，請確認磁碟已連接或重新選擇。\(error.localizedDescription)"
                    self.directoryCatalog.message = self.directoryRestoreError!
                    if self.usingModelDirectory { self.refreshStatusOnMain() }
                }
            }
        } catch {
            directoryRestoreError = "無法還原模型目錄，請重新選擇。\(error.localizedDescription)"
            directoryCatalog.message = directoryRestoreError!
            if usingModelDirectory { refreshStatusOnMain() }
        }
    }

    private func persistCatalogDirectory(_ url: URL) {
        guard let catalogDefaults else { return }
        catalogDefaults.set(AIModelDirectoryScanner.canonicalDirectoryURL(url).path, forKey: catalogPathKey)
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            catalogDefaults.set(data, forKey: catalogBookmarkKey)
        } catch {
            catalogDefaults.removeObject(forKey: catalogBookmarkKey)
            directoryCatalog.message += " 此目錄無法保存存取權限，重新開啟 App 後需再次選擇。"
        }
    }

    private func persistCatalogSelection() {
        // Installed selection itself is still held by the existing managed active-model files.
        catalogDefaults?.set(selectedDirectoryModelID.map { "directory:" + $0 } ?? "installed:", forKey: catalogSelectionKey)
    }

    private func activateManagedModels() {
        selectedDirectoryModelID = nil
        directoryRestoreError = nil
        persistCatalogSelection()
    }

    func refreshStatus() {
        performOnMain {
            // A partially committed pair must never be observed as the active model.
            guard !self.isBusy else { return }
            self.refreshStatusOnMain()
        }
    }

    private func refreshStatusOnMain() {
        status = resolveStatus()
        if !status.ready { aiEnabled = false }
    }

    func importModel(from sourceURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        performOnMain { self.beginImport(from: [sourceURL], custom: false, completion: completion) }
    }

    func importCustomModel(from sourceURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        importCustomModel(from: [sourceURL], completion: completion)
    }

    func importCustomModel(from sourceURLs: [URL], completion: @escaping (Result<Void, Error>) -> Void) {
        performOnMain { self.beginImport(from: sourceURLs, custom: true, completion: completion) }
    }

    private func beginImport(from sourceURLs: [URL], custom: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isBusy else {
            message = AIModelError.busy.localizedDescription
            completion(.failure(AIModelError.busy))
            return
        }
        let directory = ensureModelDirectory()
        let operation = AIModelImportOperation()
        importOperation = operation
        importProgress = AIImportProgress(active: true, fileName: sourceURLs.first?.lastPathComponent ?? "", totalFiles: sourceURLs.count)
        importQueue.async {
            var lastProgressTime = DispatchTime.now().uptimeNanoseconds
            var lastFile = ""
            let progress: (AIImportProgress) -> Void = { progress in
                let now = DispatchTime.now().uptimeNanoseconds
                // Avoid flooding WebKit/Combine with one update per 4 MB chunk.
                guard now - lastProgressTime >= 50_000_000 || lastFile != progress.fileName || progress.fraction >= 1 else { return }
                lastProgressTime = now
                lastFile = progress.fileName
                DispatchQueue.main.async {
                    guard self.importOperation === operation, !self.importProgress.isCancelling else { return }
                    self.importProgress = progress
                }
            }
            let result = Result<(fileName: String, binding: AIModelBinding?), Error> {
                try operation.checkCancellation()
                if custom {
                    let imported = try Self.importCustomModelFiles(from: sourceURLs, to: directory, progress: progress,
                                                                   checkCancellation: operation.checkCancellation)
                    return (imported.model.lastPathComponent, AIModelBinding(mainFileName: imported.model.lastPathComponent,
                            family: "custom", auxiliaryFileName: imported.auxiliary.lastPathComponent))
                }
                guard let sourceURL = sourceURLs.first else { throw AIModelError.invalidModelFile("") }
                let imported = try Self.importModelFile(from: sourceURL, to: directory, progress: progress,
                                                       checkCancellation: operation.checkCancellation)
                return (imported.lastPathComponent, Self.presets.first { $0.mainFile.fileName == imported.lastPathComponent }?.binding)
            }
            DispatchQueue.main.async {
                var completionResult: Result<Void, Error>
                switch result {
                case .success(let imported):
                    do {
                        try self.writeActiveModel(fileName: imported.fileName)
                        self.writeBindingMetadata(imported.binding)
                        self.activateManagedModels()
                        self.refreshStatusOnMain()
                        self.message = "\(custom ? "自訂模型已讀取" : "AI 模型已匯入")：\(imported.fileName)"
                        completionResult = .success(())
                    } catch {
                        self.refreshStatusOnMain()
                        self.message = error.localizedDescription
                        completionResult = .failure(error)
                    }
                case .failure(let error):
                    self.refreshStatusOnMain()
                    self.message = error.localizedDescription
                    completionResult = .failure(error)
                }
                self.importOperation = nil
                self.importProgress = AIImportProgress()
                completion(completionResult)
            }
        }
    }

    func cancelImport() {
        performOnMain {
            guard let operation = self.importOperation else { return }
            operation.cancel()
            self.importProgress.isCancelling = true
        }
    }

    private func performOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.async(execute: action) }
    }

    func download(_ preset: AIPresetModel) {
        performOnMain { self.performDownload(preset) }
    }

    private func performDownload(_ preset: AIPresetModel) {
        guard !isBusy else {
            message = AIModelError.busy.localizedDescription
            return
        }

        let directory = ensureModelDirectory()
        let files = [preset.mainFile] + preset.auxiliaryFiles
        let nextDownloader = AIPresetDownloader(files: files, destinationDirectory: directory) { [weak self] progress in
            self?.downloadProgress = progress
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                do {
                    try self.writeActiveModel(fileName: preset.mainFile.fileName)
                    self.writeBindingMetadata(preset.binding)
                    self.activateManagedModels()
                    self.refreshStatusOnMain()
                    self.message = "\(preset.title) 已下載並設為目前模型"
                } catch {
                    self.message = error.localizedDescription
                }
            case .failure(let error):
                self.refreshStatusOnMain()
                self.message = error.localizedDescription
            }
            self.downloader = nil
            self.downloadProgress = AIDownloadProgress()
        }

        downloader = nextDownloader
        downloadProgress = AIDownloadProgress(active: true, fileName: preset.mainFile.fileName,
                                              completedFiles: 0, totalFiles: files.count, fraction: 0, percent: 0)
        nextDownloader.start()
    }

    var repositoryDownloadDirectory: URL {
        directoryAccess?.url ?? directoryCatalog.directoryURL ?? ensureModelDirectory()
    }

    func downloadRepository(mainPath: String?, projectorPath: String?) {
        performOnMain { [self] in
            guard !self.isBusy else { self.message = AIModelError.busy.localizedDescription; return }
            do {
                let (repository, files) = try self.repositoryBrowser.downloadPlan(mainPath: mainPath, projectorPath: projectorPath)
                let root = self.repositoryDownloadDirectory
                guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      self.fileManager.isWritableFile(atPath: root.path) else {
                    throw AIModelDirectoryError.invalidDirectory
                }
                guard !AIMLXModelValidator.isCandidate(at: root) else {
                    throw AIModelRepositoryError.incomplete("目前選取的是單一 MLX 模型資料夾；請以「選取模型目錄」改選上層模型庫，避免將新權重混入原模型。")
                }
                let access = AIModelDirectoryAccess(url: root)
                let name = AIRepositoryBrowser.directoryName(repository: repository, files: files)
                let destination = root.appendingPathComponent(name, isDirectory: true)
                let format = self.repositoryBrowser.state.format
                let selectedFile = format == "mlx" ? "config.json" : (mainPath.map { ($0 as NSString).lastPathComponent } ?? "")
                let next = AIRepositoryDownloader(repository: repository, files: files, destination: destination,
                    progress: { [weak self] progress in self?.downloadProgress = progress },
                    completion: { [weak self, access] result in
                        guard let self else { return }
                        self.repositoryDownloader = nil
                        self.downloadProgress = AIDownloadProgress()
                        switch result {
                        case .success:
                            self.beginDirectoryScan(access.url, preferredID: name + "/" + selectedFile, activateFirst: false) { _ in }
                        case .failure(let error):
                            self.message = error.localizedDescription
                            self.refreshStatusOnMain()
                        }
                    })
                self.repositoryDownloader = next
                self.downloadProgress = AIDownloadProgress(active: true, fileName: repository.id, totalFiles: files.count)
                next.start()
            } catch { self.message = error.localizedDescription }
        }
    }

    func cancelDownload() {
        performOnMain {
            self.downloader?.cancel()
            self.repositoryDownloader?.cancel()
        }
    }

    func setActiveModel(fileName: String) {
        performOnMain { self.performSetActiveModel(fileName: fileName) }
    }

    private func performSetActiveModel(fileName: String) {
        guard !isBusy else {
            message = AIModelError.busy.localizedDescription
            return
        }
        do {
            let directory = ensureModelDirectory()
            guard !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0"),
                  runnableModelFiles(in: directory).contains(where: { $0.lastPathComponent == fileName }) else {
                throw AIModelError.modelMissing(directory.path)
            }
            let metadata = try binding(for: fileName, in: directory)
            try writeActiveModel(fileName: fileName)
            writeBindingMetadata(metadata)
            activateManagedModels()
            refreshStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    func deleteActiveModel() {
        performOnMain { self.performDeleteActiveModel() }
    }

    private func performDeleteActiveModel() {
        guard !isBusy else {
            message = AIModelError.busy.localizedDescription
            return
        }
        guard !usingModelDirectory else {
            message = AIModelDirectoryError.externalDeletion.localizedDescription
            return
        }
        guard !status.activeModelFileName.isEmpty else { return }
        deleteModel(fileName: status.activeModelFileName)
    }

    func delete(_ preset: AIPresetModel) {
        performOnMain { self.performDelete(preset) }
    }

    private func performDelete(_ preset: AIPresetModel) {
        guard !isBusy else {
            message = AIModelError.busy.localizedDescription
            return
        }

        deletePresetFiles(preset)
    }

    func isInstalled(_ preset: AIPresetModel) -> Bool {
        status.modelFiles.contains(preset.mainFile.fileName)
    }

    private static func importModelFile(from sourceURL: URL, to directory: URL,
                                        progress: @escaping (AIImportProgress) -> Void,
                                        checkCancellation: () throws -> Void) throws -> URL {
        let destinationURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try AIModelFileOperations.install([(sourceURL, destinationURL)], progress: progress, checkCancellation: checkCancellation)
        return destinationURL
    }

    private static func importCustomModelFiles(from sourceURLs: [URL], to destinationDirectory: URL,
                                               progress: @escaping (AIImportProgress) -> Void,
                                               checkCancellation: () throws -> Void) throws -> (model: URL, auxiliary: URL) {
        let startedAccessing = sourceURLs.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            for (url, didStart) in startedAccessing where didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let runnableSources = sourceURLs.filter(Self.isRunnableModelFile(_:))
        let selectedAuxiliarySources = sourceURLs.filter(Self.isAuxiliaryModelFile(_:))

        guard let sourceURL = AIModelPairingResolver.bestRunnableModelFile(in: runnableSources, auxiliaryCandidates: selectedAuxiliarySources) else {
            let fileName = sourceURLs.first?.lastPathComponent ?? ""
            throw AIModelError.invalidModelFile(fileName)
        }

        guard Self.isRunnableModelFile(sourceURL) else {
            throw AIModelError.invalidModelFile(sourceURL.lastPathComponent)
        }

        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let auxiliarySourceURL: URL
        if let pairedAuxiliary = AIModelPairingResolver.bestAuxiliaryModelFile(forModel: sourceURL, candidates: selectedAuxiliarySources) {
            auxiliarySourceURL = pairedAuxiliary
        } else if selectedAuxiliarySources.count == 1 {
            auxiliarySourceURL = selectedAuxiliarySources[0]
        } else {
            auxiliarySourceURL = try Self.auxiliaryModelFile(for: sourceURL, in: sourceDirectory)
        }
        let modelDestinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let auxiliaryDestinationURL = destinationDirectory.appendingPathComponent(auxiliarySourceURL.lastPathComponent)

        try Self.validateModelLoadability(at: sourceURL)
        try Self.validateModelLoadability(at: auxiliarySourceURL)
        try AIModelFileOperations.install([
            (sourceURL, modelDestinationURL),
            (auxiliarySourceURL, auxiliaryDestinationURL)
        ], progress: progress, checkCancellation: checkCancellation)

        return (modelDestinationURL, auxiliaryDestinationURL)
    }

    private func deleteModel(fileName: String) {
        do {
            let directory = ensureModelDirectory()
            let targetURL = directory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }

            if readActiveModelFileName() == fileName {
                let nextFiles = runnableModelFiles(in: directory)
                if let next = nextFiles.first {
                    try writeActiveModel(fileName: next.lastPathComponent)
                    writeBindingMetadata(Self.presets.first { $0.mainFile.fileName == next.lastPathComponent }?.binding)
                } else {
                    clearActiveModel()
                    writeBindingMetadata(nil)
                }
            }
            refreshStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    private func deletePresetFiles(_ preset: AIPresetModel) {
        do {
            let directory = ensureModelDirectory()
            let files = [preset.mainFile] + preset.auxiliaryFiles
            for file in files {
                let targetURL = directory.appendingPathComponent(file.fileName)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
            }

            if readActiveModelFileName() == preset.mainFile.fileName {
                let nextFiles = runnableModelFiles(in: directory)
                if let next = nextFiles.first {
                    try writeActiveModel(fileName: next.lastPathComponent)
                    writeBindingMetadata(Self.presets.first { $0.mainFile.fileName == next.lastPathComponent }?.binding)
                } else {
                    clearActiveModel()
                    writeBindingMetadata(nil)
                }
            }

            refreshStatus()
            message = "\(preset.title) 已刪除"
        } catch {
            message = error.localizedDescription
        }
    }

    private func resolveStatus() -> AIModelStatus {
        let directory = ensureModelDirectory()
        let modelFiles = runnableModelFiles(in: directory)
        if let selectedDirectoryModelID {
            return resolveDirectoryStatus(id: selectedDirectoryModelID, root: directoryCatalog.directoryURL,
                                          installedFiles: modelFiles.map(\.lastPathComponent))
        }
        let activeURL = resolveActiveModelURL(in: directory, modelFiles: modelFiles)
        var binding = resolvedActiveBinding(for: activeURL)

        guard let activeURL else {
            return AIModelStatus(
                ready: false,
                status: "model_missing",
                message: "尚未載入任何模型。",
                modelDirectory: directory,
                activeModelFileName: "",
                modelFiles: [],
                family: "",
                auxiliaryFileName: nil
            )
        }

        do {
            try Self.validateModelLoadability(at: activeURL)
            let auxiliaryURL: URL
            if let fileName = binding?.auxiliaryFileName, !fileName.isEmpty {
                auxiliaryURL = directory.appendingPathComponent(fileName)
                guard fileManager.fileExists(atPath: auxiliaryURL.path) else {
                    throw AIModelError.auxiliaryMissing(directory.path)
                }
            } else {
                auxiliaryURL = try Self.auxiliaryModelFile(for: activeURL, in: directory)
                binding = AIModelBinding(mainFileName: activeURL.lastPathComponent, family: "custom", auxiliaryFileName: auxiliaryURL.lastPathComponent)
            }
            try Self.validateModelLoadability(at: auxiliaryURL)
        } catch {
            return AIModelStatus(
                ready: false,
                status: "model_load_failed",
                message: error.localizedDescription,
                modelDirectory: directory,
                activeModelFileName: activeURL.lastPathComponent,
                modelFiles: modelFiles.map(\.lastPathComponent),
                family: binding?.family ?? "",
                auxiliaryFileName: binding?.auxiliaryFileName
            )
        }

        return AIModelStatus(
            ready: true,
            status: "ready",
            message: "AI 核心已就緒。",
            modelDirectory: directory,
            activeModelFileName: activeURL.lastPathComponent,
            modelFiles: modelFiles.map(\.lastPathComponent),
            family: binding?.family ?? "",
            auxiliaryFileName: binding?.auxiliaryFileName
        )
    }

    private func resolveDirectoryStatus(id: String, root: URL?, installedFiles: [String]) -> AIModelStatus {
        let entry = directoryCatalog.models.first { $0.id == id }
        let referenceURL = root.flatMap { try? AIModelDirectoryScanner.modelURL(id: id, root: $0) }
        let isMLX = entry?.format == "mlx" || referenceURL?.lastPathComponent == "config.json"
        let modelURL = isMLX ? referenceURL?.deletingLastPathComponent() : referenceURL
        var result = AIModelStatus(ready: false, status: "model_load_failed",
                                   message: directoryRestoreError ?? entry?.message ?? "目錄中的模型已不存在，請重新選擇。",
                                   modelDirectory: modelURL?.deletingLastPathComponent() ?? root ?? ensureModelDirectory(),
                                   activeModelFileName: modelURL?.lastPathComponent ?? "",
                                   modelFiles: installedFiles, family: isMLX ? "mlx" : "custom", auxiliaryFileName: entry?.auxiliaryFileName)
        guard directoryRestoreError == nil, let root, let entry, entry.ready else { return result }
        do {
            if isMLX {
                // Full tokenizer/shard validation already ran on the scan queue.
                // Keep published status updates cheap; the worker rechecks before inference.
                guard let modelURL, fileManager.isReadableFile(atPath: modelURL.appendingPathComponent("config.json").path) else {
                    throw AIModelDirectoryError.invalidDirectory
                }
            } else {
                _ = try AIModelDirectoryScanner.validate(entry: entry, root: root)
            }
            if isMLX && !AIModelRuntimeSupport.isAvailable {
                result.status = "runtime_missing"
                result.message = AIModelRuntimeSupport.availabilityMessage
                return result
            }
            result.ready = true
            result.status = "ready"
            result.message = isMLX ? "MLX 視覺模型已就緒。" : "GGUF 視覺模型已就緒。"
        } catch { result.message = error.localizedDescription }
        return result
    }

    private func resolveActiveModelURL(in directory: URL, modelFiles: [URL]) -> URL? {
        guard !modelFiles.isEmpty else { return nil }
        let activeFileName = readActiveModelFileName()
        if !activeFileName.isEmpty {
            if let activeURL = modelFiles.first(where: { $0.lastPathComponent == activeFileName }) {
                return activeURL
            }
        }
        return modelFiles.first
    }

    private func ensureModelDirectory() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStyleApp", isDirectory: true)
        let directory = customModelDirectory ?? base.appendingPathComponent(modelDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func runnableModelFiles(in directory: URL) -> [URL] {
        let files = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(Self.isRunnableModelFile(_:))

        return files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    private static func isRunnableModelFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else { return false }
        let fileName = url.lastPathComponent.lowercased()
        return !fileName.contains("mmproj")
            && !fileName.contains("vision-encoder")
            && !fileName.contains("projector")
    }

    private static func auxiliaryModelFile(in directory: URL) throws -> URL {
        try Self.auxiliaryModelFile(for: nil, in: directory)
    }

    private static func auxiliaryModelFile(for modelURL: URL?, in directory: URL) throws -> URL {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(Self.isAuxiliaryModelFile(_:))

        guard !files.isEmpty else {
            throw AIModelError.auxiliaryMissing(directory.path)
        }

        if let modelURL,
           let paired = AIModelPairingResolver.bestAuxiliaryModelFile(forModel: modelURL, candidates: files) {
            return paired
        }

        return AIModelPairingResolver.sortedByModificationDate(files).first ?? files[0]
    }

    private static func isAuxiliaryModelFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else { return false }
        let fileName = url.lastPathComponent.lowercased()
        return fileName.contains("mmproj")
            || fileName.contains("vision-encoder")
            || fileName.contains("projector")
    }

    private static func validateModelLoadability(at url: URL) throws {
        try AIModelFileOperations.validateGGUF(at: url)
    }

    private func writeActiveModel(fileName: String) throws {
        let url = ensureModelDirectory().appendingPathComponent(activeModelFileName)
        try fileName.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func binding(for fileName: String, in directory: URL) throws -> AIModelBinding? {
        let modelURL = directory.appendingPathComponent(fileName)

        if let metadata = readBindingMetadata(), metadata.mainFileName == fileName {
            return repairedCustomBinding(metadata, modelURL: modelURL, directory: directory) ?? metadata
        }

        if let presetBinding = Self.presets.first(where: { $0.mainFile.fileName == fileName })?.binding {
            return presetBinding
        }

        let auxiliaryURL = try Self.auxiliaryModelFile(for: modelURL, in: directory)
        return AIModelBinding(
            mainFileName: fileName,
            family: "custom",
            auxiliaryFileName: auxiliaryURL.lastPathComponent
        )
    }

    private func readActiveModelFileName() -> String {
        let url = ensureModelDirectory().appendingPathComponent(activeModelFileName)
        guard let data = try? Data(contentsOf: url),
              let fileName = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return ""
        }
        return fileName
    }

    private func activeModelMetadataURL() -> URL {
        ensureModelDirectory().appendingPathComponent(activeModelMetadataFileName)
    }

    private func readBindingMetadata() -> AIModelBinding? {
        guard let data = try? Data(contentsOf: activeModelMetadataURL()) else { return nil }
        return try? JSONDecoder().decode(AIModelBinding.self, from: data)
    }

    private func writeBindingMetadata(_ binding: AIModelBinding?) {
        let url = activeModelMetadataURL()
        guard let binding else {
            try? fileManager.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(binding) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearActiveModel() {
        let url = ensureModelDirectory().appendingPathComponent(activeModelFileName)
        try? fileManager.removeItem(at: url)
    }

    private func resolvedActiveBinding(for modelURL: URL?) -> AIModelBinding? {
        guard let modelURL else { return nil }
        if let metadata = readBindingMetadata(), metadata.mainFileName == modelURL.lastPathComponent {
            return repairedCustomBinding(metadata, modelURL: modelURL, directory: modelURL.deletingLastPathComponent()) ?? metadata
        }
        return Self.presets.first { $0.mainFile.fileName == modelURL.lastPathComponent }?.binding
    }

    private func repairedCustomBinding(_ binding: AIModelBinding, modelURL: URL, directory: URL) -> AIModelBinding? {
        guard binding.family == "custom" else { return binding }
        if let auxiliaryFileName = binding.auxiliaryFileName, !auxiliaryFileName.isEmpty {
            let auxiliaryURL = directory.appendingPathComponent(auxiliaryFileName)
            if fileManager.fileExists(atPath: auxiliaryURL.path),
               AIModelPairingResolver.pairingScore(modelURL: modelURL, auxiliaryURL: auxiliaryURL) > 0 {
                return binding
            }
        }

        let auxiliaryFiles = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(Self.isAuxiliaryModelFile(_:))

        guard let pairedAuxiliary = AIModelPairingResolver.bestAuxiliaryModelFile(forModel: modelURL, candidates: auxiliaryFiles),
              pairedAuxiliary.lastPathComponent != binding.auxiliaryFileName else {
            return binding
        }

        return AIModelBinding(
            mainFileName: modelURL.lastPathComponent,
            family: "custom",
            auxiliaryFileName: pairedAuxiliary.lastPathComponent
        )
    }
}
