import Foundation
import CryptoKit

struct PhotoOrganization: Codable, Equatable {
    var rating = 0
    var tags: [String] = []
}

/// Library metadata belongs to the source path, independently of editing recipes and thumbnail caches.
final class PhotoOrganizationStore {
    private struct Library: Codable {
        var version = 1
        var tags: [String] = []
        var photos: [String: PhotoOrganization] = [:]
    }
    private let fileURL: URL?
    private var library = Library()
    private var loadingError: Error?
    var tags: [String] { library.tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Library.self, from: Data(contentsOf: fileURL))
            guard saved.version == 1, Set(saved.tags).count == saved.tags.count,
                  saved.tags.allSatisfy({ (try? Self.validatedTag($0)) == $0 }),
                  saved.photos.values.allSatisfy({ (0...5).contains($0.rating)
                      && Set($0.tags).count == $0.tags.count && Set($0.tags).isSubset(of: Set(saved.tags)) }) else {
                throw Self.failure("無法讀取照片分級與分類資料。")
            }
            library = saved
        } catch { loadingError = error }
    }

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func metadata(for url: URL) -> PhotoOrganization { library.photos[Self.key(url)] ?? PhotoOrganization() }

    func setRating(_ rating: Int, for urls: [URL]) throws {
        guard (0...5).contains(rating) else { return }
        try update(urls) { metadata in metadata.rating = rating }
    }

    func setTag(_ name: String, present: Bool, for urls: [URL]) throws {
        let name = try Self.validatedTag(name)
        // Reuse the existing spelling, so differently capitalized names do not duplicate categories.
        let tag = library.tags.first { $0.compare(name, options: [.caseInsensitive]) == .orderedSame } ?? name
        try update(urls, newTag: present ? tag : nil) { metadata in
            metadata.tags.removeAll { $0 == tag }
            if present { metadata.tags.append(tag) }
            metadata.tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    func clearTags(for urls: [URL]) throws {
        try update(urls) { metadata in metadata.tags.removeAll() }
    }

    func photoCount(forTag tag: String) throws -> Int {
        if let loadingError { throw loadingError }
        return library.photos.values.filter { $0.tags.contains(tag) }.count
    }

    func removeTag(_ tag: String) throws {
        // Recheck the whole library at commit time, including other directories.
        guard try photoCount(forTag: tag) == 0 else {
            throw Self.failure("此分類仍有照片，請先移除照片的分類標記。")
        }
        guard library.tags.contains(tag) else { return }
        var next = library
        next.tags.removeAll { $0 == tag }
        try persist(next)
    }

    private func update(_ urls: [URL], newTag: String? = nil, change: (inout PhotoOrganization) -> Void) throws {
        if let loadingError { throw loadingError }
        guard !urls.isEmpty else { return }
        var next = library
        if let newTag, !next.tags.contains(newTag) { next.tags.append(newTag) }
        for url in urls {
            let key = Self.key(url)
            var metadata = next.photos[key] ?? PhotoOrganization()
            change(&metadata)
            if metadata == PhotoOrganization() { next.photos.removeValue(forKey: key) }
            else { next.photos[key] = metadata }
        }
        try persist(next)
    }

    private func persist(_ next: Library) throws {
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        }
        // Failed writes leave both the previous file and the visible state intact.
        library = next
    }

    private static func validatedTag(_ name: String) throws -> String {
        let tag = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !tag.isEmpty, tag.count <= 40,
              !tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw failure("請輸入 1～40 個字的分類名稱。")
        }
        return tag
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoOrganization", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
