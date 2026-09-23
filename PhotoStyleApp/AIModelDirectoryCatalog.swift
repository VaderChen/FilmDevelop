import Foundation

struct AIModelDirectoryEntry: Identifiable, Equatable {
    /// Relative to the selected root, so equal filenames in different folders remain distinct.
    let id: String
    let title: String
    let ready: Bool
    let message: String
    let auxiliaryFileName: String?
    var format: String = "gguf"
}

struct AIModelDirectoryCatalog: Equatable {
    var directoryURL: URL?
    var isScanning = false
    var message = "尚未選擇模型目錄。"
    var models: [AIModelDirectoryEntry] = []
}

enum AIModelDirectoryError: LocalizedError {
    case invalidDirectory
    case cancelled
    case invalidSelection
    case ambiguousAuxiliary
    case externalDeletion

    var errorDescription: String? {
        switch self {
        case .invalidDirectory: "無法讀取選擇的模型目錄。請重新選擇可讀取的資料夾。"
        case .cancelled: "模型目錄掃描已取消。"
        case .invalidSelection: "這個模型不在目前的模型清單中，請重新掃描目錄。"
        case .ambiguousAuxiliary: "同資料夾有多個 mmproj，無法確定配對。請保留單一 mmproj 或使用與主模型相同的名稱。"
        case .externalDeletion: "目錄中的模型由原資料夾管理，App 不會刪除這些檔案。"
        }
    }
}

/// Keep the original bookmark URL alive and scoped while its catalog is available, including inference.
final class AIModelDirectoryAccess {
    let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

final class AIModelDirectoryScanOperation {
    let access: AIModelDirectoryAccess
    private let lock = NSLock()
    private var cancelled = false

    init(access: AIModelDirectoryAccess) { self.access = access }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { throw AIModelDirectoryError.cancelled }
    }
}

enum AIModelDirectoryScanner {
    static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func scan(root: URL, checkCancellation: () throws -> Void) throws -> [AIModelDirectoryEntry] {
        try checkCancellation()
        let root = canonicalDirectoryURL(root)
        let manager = FileManager.default
        guard root.isFileURL,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              manager.isReadableFile(atPath: root.path) else { throw AIModelDirectoryError.invalidDirectory }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var traversalError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                 errorHandler: { _, error in traversalError = error; return false }) else {
            throw AIModelDirectoryError.invalidDirectory
        }
        var models: [URL] = []
        var mlxDirectories: [URL] = AIMLXModelValidator.isCandidate(at: root) ? [root] : []
        var projectors: [String: [URL]] = [:]
        for case let file as URL in enumerator {
            try checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            // Never walk directory aliases or follow a weight symlink outside the chosen root.
            if values.isSymbolicLink == true {
                // Foundation does not descend into symbolic links. Calling skipDescendants on a
                // non-directory entry can instead skip the next real directory on macOS.
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true, file.lastPathComponent == "config.json" {
                let directory = canonicalDirectoryURL(file.deletingLastPathComponent())
                if directory != root, AIMLXModelValidator.isCandidate(at: directory) { mlxDirectories.append(directory) }
            }
            guard values.isRegularFile == true, file.pathExtension.lowercased() == "gguf" else { continue }
            let name = file.lastPathComponent.lowercased()
            if isAuxiliary(file) {
                projectors[file.deletingLastPathComponent().path, default: []].append(file)
            } else if !isContinuationShard(name) {
                models.append(file)
            }
        }
        if let traversalError { throw traversalError }
        let candidates = try models.map { (url: $0, id: try relativeID(for: $0, root: root)) }.sorted { $0.id < $1.id }
        let ggufEntries = try candidates.map { candidate in
            try checkCancellation()
            let model = candidate.url
            let id = candidate.id
            var auxiliary: URL?
            do {
                try AIModelFileOperations.validateGGUF(at: model)
                auxiliary = try pairedAuxiliary(for: model, candidates: projectors[model.deletingLastPathComponent().path] ?? [])
                try AIModelFileOperations.validateGGUF(at: auxiliary!)
                return AIModelDirectoryEntry(id: id, title: id, ready: true, message: "可直接使用", auxiliaryFileName: auxiliary?.lastPathComponent)
            } catch {
                return AIModelDirectoryEntry(id: id, title: id, ready: false, message: error.localizedDescription, auxiliaryFileName: auxiliary?.lastPathComponent)
            }
        }
        let mlxEntries = try mlxDirectories.map { directory -> AIModelDirectoryEntry in
            try checkCancellation()
            let id = try relativeID(for: directory.appendingPathComponent("config.json"), root: root)
            let title = directory == root ? root.lastPathComponent : String(id.dropLast("/config.json".count))
            do {
                try AIMLXModelValidator.validate(at: directory)
                return AIModelDirectoryEntry(id: id, title: title, ready: true, message: "MLX 視覺模型，可直接使用",
                                             auxiliaryFileName: nil, format: "mlx")
            } catch {
                return AIModelDirectoryEntry(id: id, title: title, ready: false, message: error.localizedDescription,
                                             auxiliaryFileName: nil, format: "mlx")
            }
        }
        return (ggufEntries + mlxEntries).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func modelURL(id: String, root: URL) throws -> URL {
        let components = id.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !id.contains("\0"), !id.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw AIModelDirectoryError.invalidSelection
        }
        let root = canonicalDirectoryURL(root)
        let file = root.appendingPathComponent(id).standardizedFileURL
        let resolved = canonicalDirectoryURL(file)
        guard resolved.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/"),
              (file.pathExtension.lowercased() == "gguf" || file.lastPathComponent == "config.json") else { throw AIModelDirectoryError.invalidSelection }
        return file
    }

    static func validate(entry: AIModelDirectoryEntry, root: URL) throws -> URL {
        let model = try modelURL(id: entry.id, root: root)
        if entry.format == "mlx" {
            guard entry.ready, model.lastPathComponent == "config.json" else { throw AIModelDirectoryError.invalidSelection }
            let directory = model.deletingLastPathComponent()
            try AIMLXModelValidator.validate(at: directory)
            return directory
        }
        guard entry.ready, let auxiliaryName = entry.auxiliaryFileName else { throw AIModelDirectoryError.invalidSelection }
        let parentID = (entry.id as NSString).deletingLastPathComponent
        let auxiliaryID = parentID.isEmpty ? auxiliaryName : parentID + "/" + auxiliaryName
        let auxiliary = try modelURL(id: auxiliaryID, root: root)
        try AIModelFileOperations.validateGGUF(at: model)
        try AIModelFileOperations.validateGGUF(at: auxiliary)
        return model
    }

    private static func relativeID(for file: URL, root: URL) throws -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // Enumeration can return /private/var while standardized URLs use the /var alias.
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw AIModelDirectoryError.invalidSelection }
        return String(path.dropFirst(prefix.count))
    }

    private static func isAuxiliary(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        return name.contains("mmproj") || name.contains("vision-encoder") || name.contains("projector")
    }

    private static func isContinuationShard(_ name: String) -> Bool {
        guard let range = name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) else { return false }
        return !name[range].hasPrefix("-00001-of-")
    }

    private static func pairedAuxiliary(for model: URL, candidates: [URL]) throws -> URL {
        guard !candidates.isEmpty else { throw AIModelError.auxiliaryMissing(model.deletingLastPathComponent().path) }
        if candidates.count == 1 { return candidates[0] }
        let ranked = candidates.map { candidate -> (url: URL, score: Int) in
            var score = AIModelPairingResolver.pairingScore(modelURL: model, auxiliaryURL: candidate)
            // Also support mmproj-<model>-f16.gguf, alongside <model>.mmproj-f16.gguf.
            let name = candidate.lastPathComponent
            if name.lowercased().hasPrefix("mmproj-") || name.lowercased().hasPrefix("mmproj_") {
                let suffix = String(name.dropFirst(7))
                let named = URL(fileURLWithPath: suffix).deletingPathExtension().lastPathComponent + ".mmproj.gguf"
                score = max(score, AIModelPairingResolver.pairingScore(modelURL: model, auxiliaryURL: URL(fileURLWithPath: named)))
            }
            return (candidate, score)
        }.sorted { $0.score > $1.score }
        // Weak shared-token matches are insufficient when several vision adapters coexist.
        guard let first = ranked.first, first.score >= 80,
              ranked.dropFirst().allSatisfy({ $0.score < first.score }) else { throw AIModelDirectoryError.ambiguousAuxiliary }
        return first.url
    }
}
