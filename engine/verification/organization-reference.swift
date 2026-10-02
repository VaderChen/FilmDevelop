import Foundation
import CryptoKit

// 直接編譯原 Swift 儲存器作為參考，來源只讀；也能驗證 Go 另存的相容 JSON。
@main
struct OrganizationReference {
    struct Photo: Encodable {
        let path: String
        let id: String
        let name: String
        let rating: Int
        let tags: [String]
    }
    struct Result: Encodable { let tags: [String]; let photos: [Photo] }
    static func main() throws {
        let store = PhotoOrganizationStore(fileURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        _ = try store.photoCount(forTag: "") // 載入錯誤必須明確失敗。
        let photos = CommandLine.arguments.dropFirst(2).map { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let metadata = store.metadata(for: url)
            let id = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
            return Photo(path: url.path, id: id, name: url.lastPathComponent, rating: metadata.rating, tags: metadata.tags)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(Result(tags: store.tags, photos: photos)))
    }
}
