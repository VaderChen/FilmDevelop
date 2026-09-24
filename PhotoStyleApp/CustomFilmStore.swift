import Foundation

struct CustomFilm: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let baseStyle: String
    let adjustment: StyleAdjustment
}

/// Named recipes stay independent of the working adjustments of each photo.
final class CustomFilmStore {
    private(set) var films: [CustomFilm] = []
    private let fileURL: URL?
    private var loadingError: Error?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode([CustomFilm].self, from: Data(contentsOf: fileURL))
            guard Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ $0.id.hasPrefix("custom-") && PhotoStyle(rawValue: $0.baseStyle) != nil }) else {
                throw Self.failure("自訂底片資料無法讀取。")
            }
            films = saved
        } catch { loadingError = error }
    }

    func film(id: String?) -> CustomFilm? { films.first { $0.id == id } }

    @discardableResult
    func save(name: String, baseStyle: PhotoStyle, adjustment: StyleAdjustment, sourceID: String? = nil) throws -> CustomFilm {
        if let loadingError { throw loadingError }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Self.failure("請輸入 1～80 個字的底片名稱。")
        }
        // Only an unchanged name from the selected recipe authorizes replacement.
        let original = film(id: sourceID)
        let replacementID = original?.name == name ? original?.id : nil
        guard !films.contains(where: { $0.id != replacementID && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw Self.failure("已有同名的自訂底片，請使用其他名稱。")
        }
        let film = CustomFilm(id: replacementID ?? "custom-" + UUID().uuidString, name: name,
                              baseStyle: baseStyle.rawValue, adjustment: adjustment)
        var next = films
        if let index = next.firstIndex(where: { $0.id == replacementID }) {
            next[index] = film
        } else {
            next.append(film)
        }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        }
        films = next
        return film
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        if let loadingError { throw loadingError }
        guard films.contains(where: { $0.id == id }) else { return false }
        let next = films.filter { $0.id != id }
        if let fileURL {
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        }
        films = next
        return true
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: "CustomFilms", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
