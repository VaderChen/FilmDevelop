import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct PhotoDirectoryItem {
    let id: String
    let name: String
    let thumbnail: String?
    var isLoading = false
    var failed = false
}

// A lease survives cancelled work, so switching folders cannot revoke an active decode.
private final class PhotoDirectoryAccess: @unchecked Sendable {
    let url: URL
    private let startedAccessing: Bool
    init(_ url: URL) { self.url = url; startedAccessing = url.startAccessingSecurityScopedResource() }
    deinit { if startedAccessing { url.stopAccessingSecurityScopedResource() } }
}

private final class PhotoDirectoryOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct PhotoDirectoryDiagnostics {
    var headerReads = 0
    var memoryHits = 0
    var diskHits = 0
    var thumbnailDecodes = 0
    var embeddedThumbnails = 0
    var generatedThumbnails = 0
    var activeDecodes = 0
    var peakConcurrentDecodes = 0
}

// Only small display derivatives are cached; originals continue through the FP32 pipeline.
// File metadata and a format version invalidate derivatives after a source or algorithm change.
private final class PhotoThumbnailCache: @unchecked Sendable {
    private let memory = NSCache<NSString, NSData>()
    private let lock = NSLock()
    private var counters = PhotoDirectoryDiagnostics()
    private let directory: URL
    private let maintenance = DispatchQueue(label: "person.vader.PhotoStyleApp.thumbnail-cache", qos: .utility)
    private var maintenancePending = false
    private static let version = "thumbnail-256-embedded-v2"
    private static let maxDiskBytes = 256 * 1024 * 1024

    init(directory: URL) {
        self.directory = directory
        memory.totalCostLimit = 32 * 1024 * 1024
        memory.countLimit = 512
    }
    var diagnostics: PhotoDirectoryDiagnostics { lock.withLock { counters } }
    func record(_ action: (inout PhotoDirectoryDiagnostics) -> Void) { lock.withLock { action(&counters) } }

    static func key(id: String, values: URLResourceValues) -> String {
        let value = "\(version)\n\(id)\n\(values.fileSize ?? -1)\n\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return digest(value)
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func inMemory(_ key: String) -> Data? {
        guard let data = memory.object(forKey: key as NSString) else { return nil }
        record { $0.memoryHits += 1 }
        return data as Data
    }
    func onDisk(_ key: String) -> Data? {
        let url = directory.appendingPathComponent(key + ".jpg")
        guard let data = try? Data(contentsOf: url), data.count < 2 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1 else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        record { $0.diskHits += 1 }
        return data
    }
    func insert(_ data: Data, key: String) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
        } catch { /* A full/unwritable cache must never prevent browsing originals. */ }
    }
    func validations(for directoryID: String) -> [String: Bool] {
        guard let data = try? Data(contentsOf: validationURL(directoryID)), data.count <= 2 * 1024 * 1024,
              let result = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return result
    }
    func saveValidations(_ validations: [String: Bool], directoryID: String) {
        // Do not let a single very large directory turn the cache index into unbounded state.
        let bounded = Dictionary(uniqueKeysWithValues: validations.prefix(20_000).map { ($0.key, $0.value) })
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: validationURL(directoryID), options: .atomic)
        scheduleMaintenance()
    }
    private func validationURL(_ id: String) -> URL {
        directory.appendingPathComponent(Self.digest(Self.version + id) + ".json")
    }
    func scheduleMaintenance() {
        guard lock.withLock({ () -> Bool in
            guard !maintenancePending else { return false }
            maintenancePending = true
            return true
        }) else { return }
        maintenance.async { [self] in
            defer { lock.withLock { maintenancePending = false } }
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            var files: [(URL, Int, Date)] = entries.compactMap { url in
                guard ["jpg", "json"].contains(url.pathExtension),
                      let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            var bytes = files.reduce(0) { $0 + $1.1 }
            guard bytes > Self.maxDiskBytes || files.count > 4096 else { return }
            files.sort { $0.2 < $1.2 }
            var count = files.count
            for (url, size, _) in files where bytes > Self.maxDiskBytes || count > 4096 {
                if (try? FileManager.default.removeItem(at: url)) != nil { bytes -= size; count -= 1 }
            }
        }
    }
}

// Main-thread state; enumeration and a globally bounded pool of thumbnail workers stay off WebKit.
final class PhotoDirectoryStore {
    private struct Entry {
        let url: URL
        let id: String
        let cacheKey: String
        var name: String { url.lastPathComponent }
    }
    var onChange: (() -> Void)?
    private(set) var directoryURL: URL?
    private(set) var isScanning = false
    private(set) var isLoadingThumbnails = false
    private(set) var items: [PhotoDirectoryItem] = []
    private(set) var message = ""
    var totalCount: Int { urls.count }
    var diagnostics: PhotoDirectoryDiagnostics { cache.diagnostics }

    private let queue = DispatchQueue(label: "person.vader.PhotoStyleApp.photo-directory", qos: .userInitiated)
    private let workers: OperationQueue
    private let cache: PhotoThumbnailCache
    private var access: PhotoDirectoryAccess?
    private var scanOperation: PhotoDirectoryOperation?
    private var thumbnailOperation: PhotoDirectoryOperation?
    private var thumbnailPublication: DispatchWorkItem?
    private var pendingThumbnails: [String: String] = [:]
    private var pendingFailures: Set<String> = []
    private var requestedIDs: Set<String> = []
    private var thumbnailWork: [String: PhotoDirectoryOperation] = [:]
    private var preferredPhotoID: String?
    private var urls: [Entry] = []
    private var urlsByID: [String: URL] = [:]

    init(cacheDirectory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cache = PhotoThumbnailCache(directory: cacheDirectory ?? base
            .appendingPathComponent("PhotoStyleApp/PhotoThumbnails", isDirectory: true))
        workers = OperationQueue()
        workers.name = "person.vader.PhotoStyleApp.photo-thumbnails"
        workers.qualityOfService = .userInitiated
        workers.maxConcurrentOperationCount = 4
    }
    deinit {
        scanOperation?.cancel(); thumbnailOperation?.cancel()
        thumbnailPublication?.cancel(); workers.cancelAllOperations()
        thumbnailWork.values.forEach { $0.cancel() }
    }

    func selectDirectory(_ url: URL, preferredPhotoURL: URL? = nil) {
        scanOperation?.cancel()
        thumbnailOperation?.cancel()
        thumbnailPublication?.cancel()
        workers.cancelAllOperations()
        thumbnailWork.values.forEach { $0.cancel() }
        thumbnailWork = [:]
        requestedIDs = []
        preferredPhotoID = preferredPhotoURL.map(Self.identity(for:))
        let operation = PhotoDirectoryOperation()
        let access = PhotoDirectoryAccess(url)
        self.access = access
        scanOperation = operation
        thumbnailOperation = nil
        directoryURL = url
        isScanning = true
        isLoadingThumbnails = false
        items = []
        urls = []
        urlsByID = [:]
        message = "正在讀取照片目錄…"
        onChange?()
        let cache = cache
        queue.async { [weak self, access] in
            let result = Result { try Self.scan(access.url, operation: operation, cache: cache) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanOperation === operation, !operation.isCancelled else { return }
                self.scanOperation = nil
                self.isScanning = false
                switch result {
                case .success(let urls):
                    self.urls = urls
                    self.urlsByID = Dictionary(urls.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
                    self.message = urls.isEmpty ? "此目錄沒有可讀取的照片或 RAW 檔案。" : ""
                    self.prepareItems()
                case .failure(let error):
                    self.message = "無法讀取照片目錄：\(error.localizedDescription)"
                    self.onChange?()
                }
            }
        }
    }

    func url(for id: String) -> URL? { urlsByID[id] }

    func payload(selectedURL: URL?) -> [String: Any] {
        let selectedID = selectedURL.map(Self.identity(for:))
        return [
            "name": directoryURL?.lastPathComponent ?? "", "path": directoryURL?.path ?? "",
            "isScanning": isScanning, "isLoadingThumbnails": isLoadingThumbnails,
            "items": items.map { item -> [String: Any] in
                ["id": item.id, "name": item.name, "thumbnail": item.thumbnail as Any? ?? NSNull(),
                 "selected": item.id == selectedID, "isLoading": item.isLoading, "failed": item.failed]
            },
            "totalCount": totalCount, "message": message
        ]
    }

    private func prepareItems() {
        thumbnailOperation?.cancel()
        thumbnailPublication?.cancel()
        thumbnailPublication = nil
        workers.cancelAllOperations()
        thumbnailWork.values.forEach { $0.cancel() }
        thumbnailWork = [:]
        pendingThumbnails = [:]
        pendingFailures = []
        requestedIDs = []
        thumbnailOperation = PhotoDirectoryOperation()
        // Even cached derivatives are requested only after the web viewport reports visibility.
        items = urls.map { .init(id: $0.id, name: $0.name, thumbnail: nil) }
        isLoadingThumbnails = false
        onChange?()
    }

    /// IDs are the complete currently visible viewport, not a prefetch list.
    /// Header enumeration never starts thumbnail decoding. Repeated observer events are no-ops.
    func requestThumbnails(ids: [String]) {
        guard !isScanning, let operation = thumbnailOperation, let access else { return }
        let wanted = Set(ids.lazy.filter { self.urlsByID[$0] != nil }.prefix(48))
        guard wanted != requestedIDs else { return }
        requestedIDs = wanted
        for (id, work) in thumbnailWork where !wanted.contains(id) {
            work.cancel()
            thumbnailWork.removeValue(forKey: id)
        }
        // A viewport update can arrive before a scheduled progress publication.
        applyPendingThumbnails()
        let readyIDs = Set(items.filter { $0.thumbnail != nil || $0.failed }.map(\.id))
        let missing = urls.filter { wanted.contains($0.id) && !readyIDs.contains($0.id) && thumbnailWork[$0.id] == nil }
            .sorted { $0.id == preferredPhotoID && $1.id != preferredPhotoID }
        let cache = cache
        for entry in missing {
            if let data = cache.inMemory(entry.cacheKey) {
                pendingThumbnails[entry.id] = Self.dataURL(data)
                continue
            }
            let work = PhotoDirectoryOperation()
            thumbnailWork[entry.id] = work
            workers.addOperation { [weak self, access] in
                guard !operation.isCancelled, !work.isCancelled else { return }
                let thumbnail: String? = withExtendedLifetime(access) {
                    autoreleasepool {
                        if let data = cache.inMemory(entry.cacheKey) ?? cache.onDisk(entry.cacheKey) {
                            return Self.dataURL(data)
                        }
                        guard !operation.isCancelled, !work.isCancelled,
                              let data = Self.thumbnail(for: entry.url, cache: cache) else { return nil }
                        cache.insert(data, key: entry.cacheKey)
                        return Self.dataURL(data)
                    }
                }
                guard !operation.isCancelled, !work.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.thumbnailOperation === operation,
                          self.thumbnailWork[entry.id] === work, !operation.isCancelled, !work.isCancelled else { return }
                    self.thumbnailWork.removeValue(forKey: entry.id)
                    if let thumbnail { self.pendingThumbnails[entry.id] = thumbnail }
                    else { self.pendingFailures.insert(entry.id) }
                    if self.thumbnailWork.isEmpty {
                        self.publishThumbnails(operation: operation)
                        cache.scheduleMaintenance()
                    } else if self.thumbnailPublication == nil {
                        let publication = DispatchWorkItem { [weak self] in self?.publishThumbnails(operation: operation) }
                        self.thumbnailPublication = publication
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: publication)
                    }
                }
            }
        }
        applyPendingThumbnails()
        onChange?()
    }

    private func applyPendingThumbnails() {
        items = items.map { item in
            .init(id: item.id, name: item.name,
                  thumbnail: requestedIDs.contains(item.id) ? (pendingThumbnails[item.id] ?? item.thumbnail) : nil,
                  isLoading: thumbnailWork[item.id] != nil,
                  failed: pendingFailures.contains(item.id) || item.failed)
        }
        pendingThumbnails.removeAll(keepingCapacity: true)
        pendingFailures.removeAll(keepingCapacity: true)
        isLoadingThumbnails = !thumbnailWork.isEmpty
    }

    private func publishThumbnails(operation: PhotoDirectoryOperation) {
        guard thumbnailOperation === operation, !operation.isCancelled else { return }
        thumbnailPublication?.cancel()
        thumbnailPublication = nil
        applyPendingThumbnails()
        onChange?()
    }

    private static func identity(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().absoluteString
    }
    private static func dataURL(_ data: Data) -> String { "data:image/jpeg;base64," + data.base64EncodedString() }

    private static func scan(_ directory: URL, operation: PhotoDirectoryOperation, cache: PhotoThumbnailCache) throws -> [Entry] {
        guard directory.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else {
            throw NSError(domain: "PhotoDirectory", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "選取的路徑不是資料夾。"])
        }
        let directoryID = identity(for: directory)
        let previousValidations = cache.validations(for: directoryID)
        var validations: [String: Bool] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        let candidates = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var readable: [Entry] = []
        for candidate in candidates {
            guard !operation.isCancelled else { return [] }
            guard !candidate.lastPathComponent.hasPrefix("."),
                  let values = try? candidate.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true, values.isHidden != true,
                  mayContainImage(candidate) else { continue }
            let id = identity(for: candidate)
            let key = PhotoThumbnailCache.key(id: id, values: values)
            let isReadable: Bool
            if let previous = previousValidations[key] { isReadable = previous }
            else {
                cache.record { $0.headerReads += 1 }
                isReadable = autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(candidate as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
                    return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
                }
            }
            validations[key] = isReadable
            if isReadable { readable.append(.init(url: candidate, id: id, cacheKey: key)) }
        }
        guard !operation.isCancelled else { return [] }
        cache.saveValidations(validations, directoryID: directoryID)
        return readable.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    private static func mayContainImage(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) || type.conforms(to: .rawImage) { return true }
        return ["3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq", "kdc", "mef", "mos",
                "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "srw", "x3f"]
            .contains(url.pathExtension.lowercased())
    }

    private static func thumbnail(for url: URL, cache: PhotoThumbnailCache) -> Data? {
        cache.record {
            $0.thumbnailDecodes += 1
            $0.activeDecodes += 1
            $0.peakConcurrentDecodes = max($0.peakConcurrentDecodes, $0.activeDecodes)
        }
        defer { cache.record { $0.activeDecodes -= 1 } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // Many RAW/JPEG files already contain a camera preview. Use it before requesting
        // a fresh decode/demosaic of the full source, particularly for large camera RAWs.
        var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        if image != nil { cache.record { $0.embeddedThumbnails += 1 } }
        else {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            if image != nil { cache.record { $0.generatedThumbnails += 1 } }
        }
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
