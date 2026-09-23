import AppKit
import CoreImage
import CryptoKit

/// Photo recipes are documents, not a discardable thumbnail cache.
struct PhotoEditRecord: Codable, Equatable {
    var version = 1
    let selectedStyle: String
    var customFilmID: String?
    var customFilmBaseAdjustment: StyleAdjustment?
    let adjustments: [String: StyleAdjustment]

    init(style: PhotoStyle, adjustments: [PhotoStyle: StyleAdjustment], customFilmID: String? = nil, customFilmBaseAdjustment: StyleAdjustment? = nil) {
        selectedStyle = style.rawValue
        self.customFilmID = customFilmID
        self.customFilmBaseAdjustment = customFilmBaseAdjustment
        self.adjustments = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) })
    }
}

final class PhotoEditStore {
    private final class Entry: NSObject {
        let record: PhotoEditRecord
        let mask: CIImage?
        init(_ record: PhotoEditRecord, mask: CIImage?) { self.record = record; self.mask = mask }
    }

    let directory: URL?
    private let queue = DispatchQueue(label: "person.vader.PhotoStyleApp.photoEdits", qos: .utility)
    private let cache = NSCache<NSString, Entry>()
    private var volatileRecords: [String: Entry] = [:]
    private var editedPhotos: [String: Bool] = [:]
    private var failedWrites: Set<String> = []
    private static let maskContext = PhotoImageRenderPrecision.makeContext()
    private static let maskColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    var onError: ((Error) -> Void)?

    init(directory: URL?) {
        self.directory = directory
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("edited-photos.json")) {
            if let saved = try? JSONDecoder().decode([String: Bool].self, from: data) { editedPhotos = saved }
            else if let legacy = try? JSONDecoder().decode(Set<String>.self, from: data) {
                editedPhotos = Dictionary(uniqueKeysWithValues: legacy.map { ($0, true) })
            }
        }
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private static func editedKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func hasEdits(at url: URL) -> Bool {
        editedPhotos[Self.editedKey(url)] == true
    }

    @discardableResult
    func markEdited(at url: URL) -> Bool {
        setEdited(true, at: url)
    }

    func hasRecordedEditState(at url: URL) -> Bool { editedPhotos[Self.editedKey(url)] != nil }

    func clearEdited(at url: URL) { _ = setEdited(false, at: url) }

    private func setEdited(_ edited: Bool, at url: URL) -> Bool {
        let key = Self.editedKey(url)
        guard editedPhotos[key] != edited else { return false }
        editedPhotos[key] = edited
        let snapshot = editedPhotos
        queue.async { [weak self] in
            guard let self, let directory = self.directory else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("edited-photos.json"), options: .atomic)
            } catch { DispatchQueue.main.async { [weak self] in self?.onError?(error) } }
        }
        return true
    }

    static func key(identifier: String?, url: URL?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        // Equal filenames (and even duplicate file contents) remain separate photos.
        // Replacing bytes at the same path also creates a new recipe identity.
        let path = url?.standardizedFileURL.resolvingSymlinksInPath().path ?? "memory"
        return SHA256.hash(data: Data((path + "\n" + identifier).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func record(for key: String) -> PhotoEditRecord? {
        queue.sync {
            if let entry = cache.object(forKey: key as NSString) ?? volatileRecords[key] { return entry.record }
            guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
                  let record = try? JSONDecoder().decode(PhotoEditRecord.self, from: data),
                  record.version == 1, PhotoStyle(rawValue: record.selectedStyle) != nil else { return nil }
            return record
        }
    }

    func mask(for key: String, size: CGSize) -> CIImage? {
        queue.sync {
            let entry = cache.object(forKey: key as NSString) ?? volatileRecords[key]
            let memory = entry?.mask
            let disk = directory.flatMap { directory -> CIImage? in
                guard entry == nil,
                      let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".mask.rgba")),
                      data.count >= 16, data.prefix(8) == Data("FYPMASK1".utf8) else { return nil }
                let width = data[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                let height = data[12..<16].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard width > 0, height > 0, width <= 4096, height <= 4096,
                      CGSize(width: width, height: height) == size, data.count == 16 + width * height * 16 else { return nil }
                return CIImage(bitmapData: data.subdata(in: 16..<data.count), bytesPerRow: width * 16,
                               size: size, format: .RGBAf, colorSpace: Self.maskColorSpace)
            }
            guard let mask = memory ?? disk, mask.extent.origin == .zero, mask.extent.size == size else { return nil }
            return mask
        }
    }

    func save(_ record: PhotoEditRecord, mask: CIImage?, for key: String) {
        queue.async { [self] in
            let previous = cache.object(forKey: key as NSString) ?? volatileRecords[key]
            guard failedWrites.contains(key) || previous?.record != record || previous?.mask !== mask else { return }
            let entry = Entry(record, mask: mask)
            let maskCost = mask.map { Int($0.extent.width * $0.extent.height) * 16 } ?? 0
            cache.setObject(entry, forKey: key as NSString, cost: maskCost + 64 * 1024)
            guard let directory else { volatileRecords[key] = entry; return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Keep the existing subject segmentation: reopening never needs to ask AI again.
                if let mask, previous?.mask !== mask || failedWrites.contains(key) {
                    let width = Int(mask.extent.width), height = Int(mask.extent.height)
                    guard mask.extent.origin == .zero, width > 0, height > 0, width <= 4096, height <= 4096 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    // Raw FP32 avoids an image codec/ICC round trip altering mask weights.
                    var data = Data("FYPMASK1".utf8)
                    for value in [UInt32(width).littleEndian, UInt32(height).littleEndian] {
                        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
                    }
                    data.append(Data(count: width * height * 16))
                    data.withUnsafeMutableBytes { bytes in
                        Self.maskContext.render(mask, toBitmap: bytes.baseAddress!.advanced(by: 16),
                            rowBytes: width * 16, bounds: mask.extent, format: .RGBAf, colorSpace: Self.maskColorSpace)
                    }
                    try data.write(to: directory.appendingPathComponent(key + ".mask.rgba"), options: .atomic)
                } else if mask == nil {
                    let maskURL = directory.appendingPathComponent(key + ".mask.rgba")
                    if FileManager.default.fileExists(atPath: maskURL.path) { try FileManager.default.removeItem(at: maskURL) }
                }
                let data = try JSONEncoder().encode(record)
                try data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
                failedWrites.remove(key)
                volatileRecords.removeValue(forKey: key)
            } catch {
                // Retain the in-session recipe and allow the next edit to retry persistence.
                cache.removeObject(forKey: key as NSString)
                volatileRecords[key] = entry
                failedWrites.insert(key)
                DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            }
        }
    }

    @MainActor func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
