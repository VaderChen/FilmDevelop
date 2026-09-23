import Foundation
import Darwin

/// One repository package is published only after every file has passed validation.
/// Like Tanpopo, cancellation removes this attempt's partial files; it is not resumable.
final class AIRepositoryDownloader: NSObject, URLSessionDownloadDelegate {
    private let repository: AIHubRepository
    private let files: [AIHubFile]
    private let requestedDestination: URL
    private let progressHandler: (AIDownloadProgress) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private let workQueue = DispatchQueue(label: "person.vader.PhotoStyleApp.repositoryDownload", qos: .utility)
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var started = false
    private var finished = false
    private var staging: URL?
    private var destination: URL?
    private var currentIndex = 0
    private var currentTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var localPaths: [String] = []
    private var receivedBytes: [Int64]
    private var isGGUF = false
    private var lastProgressTime: UInt64 = 0
    private var lastProgressIndex = -1

    init(repository: AIHubRepository, files: [AIHubFile], destination: URL,
         progress: @escaping (AIDownloadProgress) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.repository = repository
        self.files = files
        self.requestedDestination = destination
        self.progressHandler = progress
        self.completion = completion
        self.receivedBytes = Array(repeating: 0, count: files.count)
        super.init()
    }

    func start() {
        workQueue.async {
            guard !self.started, !self.finished else { return }
            self.started = true
            do {
                try self.checkCancellation()
                try self.prepare()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                delegateQueue.underlyingQueue = self.workQueue
                self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
                self.startNextFile()
            } catch { self.finish(.failure(error)) }
        }
    }

    func cancel() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        workQueue.async {
            guard !self.finished else { return }
            self.finish(.failure(AIModelRepositoryError.cancelled))
        }
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        let cancelled = cancellationRequested
        cancellationLock.unlock()
        if cancelled { throw AIModelRepositoryError.cancelled }
    }

    private func prepare() throws {
        guard !files.isEmpty, files.count <= 20_000, requestedDestination.isFileURL,
              !requestedDestination.lastPathComponent.isEmpty else { throw AIModelRepositoryError.invalidPath(requestedDestination.path) }
        isGGUF = files.contains { $0.path.lowercased().hasSuffix(".gguf") }
        guard !isGGUF || !files.contains(where: { $0.path.lowercased().hasSuffix(".safetensors") }) else {
            throw AIModelRepositoryError.incomplete("單次下載不可混合 GGUF 與 MLX 權重")
        }
        if isGGUF {
            guard files.filter({ AIModelRepositoryClient.isPrimaryGGUF($0.path) }).count == 1,
                  files.filter({ AIModelRepositoryClient.isProjector($0.path) }).count == 1 else {
                throw AIModelRepositoryError.incomplete("照片模型需要一個 GGUF 主模型與一個 mmproj")
            }
        }
        let available = Set(repository.files)
        var unique = Set<String>()
        localPaths = try files.map { file in
            try AIModelRepositoryClient.validatePath(file.path)
            guard available.contains(file), ["https", "http"].contains(file.url.scheme?.lowercased() ?? ""),
                  file.url.host != nil, file.url.user == nil, file.url.password == nil,
                  file.size == nil || file.size! >= 0 else { throw AIModelRepositoryError.invalidResponse(file.path) }
            let path = isGGUF ? (file.path as NSString).lastPathComponent : file.path
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard path != "photostyle-download.json", unique.insert(key).inserted else {
                throw AIModelRepositoryError.invalidPath("重複目的檔案：\(path)")
            }
            return path
        }
        for path in unique {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !unique.contains(parent) else { throw AIModelRepositoryError.invalidPath(path) }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let manager = FileManager.default
        let parent = requestedDestination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              manager.isWritableFile(atPath: parent.path) else {
            throw AIModelRepositoryError.incomplete("下載目錄不存在或無法寫入，請確認磁碟已連接並重新選擇目錄")
        }
        let target = parent.appendingPathComponent(requestedDestination.lastPathComponent, isDirectory: true)
        var info = stat()
        if lstat(target.path, &info) == 0 { throw AIModelRepositoryError.destinationExists }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = parent.appendingPathComponent(".photostyle-download-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(temporary.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        staging = temporary
        destination = target
    }

    private func startNextFile() {
        do {
            try checkCancellation()
            guard currentIndex < files.count else { try commit(); return }
            var request = URLRequest(url: files[currentIndex].url)
            request.setValue("PhotoStyleApp/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            currentTask = session?.downloadTask(with: request)
            publishProgress()
            currentTask?.resume()
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard !finished, downloadTask === currentTask, currentIndex < files.count else { return }
        receivedBytes[currentIndex] = max(totalBytesWritten, 0)
        if let expected = files[currentIndex].size, totalBytesWritten > expected {
            finish(.failure(AIModelRepositoryError.incomplete("\(files[currentIndex].path) 大小超出清單")))
            return
        }
        publishProgress(expectedForCurrent: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !finished, downloadTask === currentTask, currentIndex < files.count, let staging else { return }
        do {
            try checkCancellation()
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw AIModelRepositoryError.invalidResponse("非 HTTP 回應")
            }
            guard response.statusCode == 200 else { throw AIModelRepositoryError.http(response.statusCode) }
            let file = files[currentIndex]
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size >= 0, file.size == nil || size == file.size,
                  response.expectedContentLength < 0 || size == response.expectedContentLength else {
                throw AIModelRepositoryError.incomplete("\(file.path) 大小不符")
            }
            if file.path.lowercased().hasSuffix(".gguf") { try AIModelFileOperations.validateGGUF(at: location) }
            let target = staging.appendingPathComponent(localPaths[currentIndex])
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            receivedBytes[currentIndex] = size
            currentIndex += 1
            currentTask = nil
            publishProgress()
            startNextFile()
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished, task === currentTask, let error else { return }
        do { try checkCancellation(); finish(.failure(error)) }
        catch { finish(.failure(error)) }
    }

    private func commit() throws {
        guard let staging, let destination else { throw AIModelRepositoryError.incomplete("缺少暫存目錄") }
        try checkCancellation()
        if !isGGUF { try AIMLXModelValidator.validate(at: staging) }
        struct Manifest: Encodable {
            struct File: Encodable { let path: String; let localPath: String; let size: Int64 }
            let schemaVersion = 1
            let repository: String
            let revision: String
            let format: String
            let files: [File]
        }
        let manifest = Manifest(repository: repository.id, revision: repository.revision, format: isGGUF ? "gguf" : "mlx",
            files: files.indices.map { Manifest.File(path: files[$0].path, localPath: localPaths[$0], size: receivedBytes[$0]) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("photostyle-download.json"), options: .atomic)
        try checkCancellation()
        // Same-parent exclusive rename cannot replace an existing directory, even if it
        // appeared after prepare(). There is no copy fallback or deletion of user files.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw AIModelRepositoryError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.staging = nil
        finish(.success(destination))
    }

    private func publishProgress(expectedForCurrent: Int64 = -1) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastProgressIndex != currentIndex || now - lastProgressTime >= 50_000_000 else { return }
        lastProgressIndex = currentIndex
        lastProgressTime = now
        let fraction: Double
        if files.allSatisfy({ ($0.size ?? 0) > 0 }) {
            let total = files.reduce(0.0) { $0 + Double($1.size!) }
            fraction = min(receivedBytes.reduce(0.0) { $0 + Double($1) } / total, 1)
        } else {
            let partial = currentIndex < files.count && expectedForCurrent > 0
                ? min(Double(receivedBytes[currentIndex]) / Double(expectedForCurrent), 1) : 0
            fraction = min((Double(currentIndex) + partial) / Double(files.count), 1)
        }
        let progress = AIDownloadProgress(active: true,
            fileName: currentIndex < files.count ? files[currentIndex].path : files.last?.path ?? "",
            completedFiles: currentIndex, totalFiles: files.count,
            fraction: fraction, percent: Int((fraction * 100).rounded()))
        DispatchQueue.main.async { self.progressHandler(progress) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        var result = result
        if let staging {
            do { try FileManager.default.removeItem(at: staging) }
            catch { result = .failure(error) }
        }
        staging = nil
        DispatchQueue.main.async { self.completion(result) }
    }
}
