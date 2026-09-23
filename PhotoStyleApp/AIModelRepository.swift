import Foundation

// The repository/format workflow follows Tanpopo's src/download/manager.go.
// This client deliberately pins every asset to one commit and plans one complete model.
struct AIHubFile: Hashable, Codable {
    let path: String
    let size: Int64?
    let url: URL
}

struct AIHubSearchResult: Identifiable, Equatable {
    let id: String
    let downloads: Int64
    let likes: Int64
}

struct AIHubRepository: Equatable {
    let id: String
    /// Immutable repository commit, never the moving `main` branch.
    let revision: String
    let files: [AIHubFile]

    var ggufModels: [AIHubFile] {
        files.filter { AIModelRepositoryClient.isPrimaryGGUF($0.path) }.sorted { $0.path < $1.path }
    }

    var projectorFiles: [AIHubFile] {
        files.filter { AIModelRepositoryClient.isProjector($0.path) }.sorted { $0.path < $1.path }
    }
}

enum AIModelRepositoryError: LocalizedError {
    case invalidRepository
    case invalidPath(String)
    case invalidResponse(String)
    case http(Int)
    case incomplete(String)
    case destinationExists
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRepository: "請輸入 owner/model，或 https://huggingface.co/owner/model。"
        case .invalidPath(let path): "模型檔案路徑無效：\(path)"
        case .invalidResponse(let detail): "Hugging Face 回應無效：\(detail)"
        case .http(let status): "Hugging Face 下載失敗（HTTP \(status)）。"
        case .incomplete(let detail): "模型檔案不完整：\(detail)"
        case .destinationExists: "目的模型資料夾已存在，請選擇新的下載位置。"
        case .cancelled: "模型下載已取消。"
        }
    }
}

enum AIModelRepositoryClient {
    static let endpoint = URL(string: "https://huggingface.co")!

    private struct RepositoryResponse: Decodable {
        let id: String?
        let sha: String?
        let downloads: Int64?
        let likes: Int64?
        let siblings: [Sibling]?
    }

    private struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let size: Int64? }
    }

    static func search(query: String, format: String, session: URLSession = .shared,
                       endpoint: URL = endpoint) async throws -> [AIHubSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100, !query.contains(where: { $0.isNewline || $0 == "\0" }),
              ["gguf", "mlx"].contains(format.lowercased()) else { throw AIModelRepositoryError.invalidRepository }
        var components = URLComponents(url: endpoint.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "limit", value: "50"),
                                 URLQueryItem(name: "full", value: "true")]
        let data = try await read(components.url!, session: session, limit: 8 * 1024 * 1024)
        let responses = try JSONDecoder().decode([RepositoryResponse].self, from: data)
        var seen = Set<String>()
        return responses.compactMap { response in
            guard let id = response.id, (try? repositoryID(id)) != nil, seen.insert(id).inserted else { return nil }
            let paths = (response.siblings ?? []).map(\.rfilename).filter { (try? validatePath($0)) != nil }
            let matches = format.lowercased() == "gguf" ? paths.contains(where: isPrimaryGGUF)
                : paths.contains("config.json") && paths.contains(where: { !$0.contains("/") && $0.hasSuffix(".safetensors") })
            guard matches else { return nil }
            return AIHubSearchResult(id: id, downloads: max(response.downloads ?? 0, 0), likes: max(response.likes ?? 0, 0))
        }
    }

    static func inspect(_ input: String, session: URLSession = .shared,
                        endpoint: URL = endpoint) async throws -> AIHubRepository {
        let id = try repositoryID(input)
        var components = URLComponents(url: endpoint.appendingPathComponent("api/models").appendingPathComponent(id)
            .appendingPathComponent("revision/main"), resolvingAgainstBaseURL: false)!
        // blobs adds the expected byte length for LFS files as well as ordinary assets.
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        let data = try await read(components.url!, session: session, limit: 8 * 1024 * 1024)
        let response = try JSONDecoder().decode(RepositoryResponse.self, from: data)
        guard let commit = response.sha, commit.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil,
              let siblings = response.siblings, siblings.count <= 20_000 else {
            throw AIModelRepositoryError.invalidResponse("缺少固定版本或檔案清單")
        }
        var paths = Set<String>()
        let files = try siblings.map { sibling -> AIHubFile in
            try validatePath(sibling.rfilename)
            guard paths.insert(sibling.rfilename).inserted else { throw AIModelRepositoryError.invalidResponse("重複檔案") }
            let size = sibling.lfs?.size ?? sibling.size
            guard size == nil || size! >= 0 else { throw AIModelRepositoryError.invalidResponse("檔案大小無效") }
            var url = endpoint.appendingPathComponent(id).appendingPathComponent("resolve").appendingPathComponent(commit)
            for component in sibling.rfilename.split(separator: "/") { url.appendPathComponent(String(component)) }
            return AIHubFile(path: sibling.rfilename, size: size, url: url)
        }
        return AIHubRepository(id: id, revision: commit, files: files)
    }

    static func mlxFiles(in repository: AIHubRepository, session: URLSession = .shared) async throws -> [AIHubFile] {
        var files: [String: AIHubFile] = [:]
        for file in repository.files {
            try validatePath(file.path)
            guard files.updateValue(file, forKey: file.path) == nil else { throw AIModelRepositoryError.invalidResponse("重複檔案") }
        }
        guard let configuration = files["config.json"] else { throw AIModelRepositoryError.incomplete("缺少根目錄 config.json") }
        let config = try await json(configuration, session: session)
        guard let modelType = config["model_type"] as? String, AIMLXModelValidator.supports(modelType: modelType),
              let vision = config["vision_config"] as? [String: Any], !vision.isEmpty else {
            throw AIModelRepositoryError.incomplete("照片分析需要含 vision_config 的視覺模型")
        }
        var selected = Set(["config.json"])
        if let index = files["model.safetensors.index.json"] {
            let content = try await json(index, session: session)
            guard let map = content["weight_map"] as? [String: String], !map.isEmpty else {
                throw AIModelRepositoryError.incomplete("safetensors index 無效")
            }
            selected.insert(index.path)
            for path in Set(map.values) {
                try validatePath(path)
                guard path.hasSuffix(".safetensors"), files[path] != nil else { throw AIModelRepositoryError.incomplete(path) }
                selected.insert(path)
            }
        } else {
            guard files["model.safetensors"] != nil else {
                throw AIModelRepositoryError.incomplete("缺少 model.safetensors 或完整分片 index")
            }
            selected.insert("model.safetensors")
        }
        let assets: Set<String> = ["tokenizer.json", "tokenizer_config.json", "tokenizer.model", "sentencepiece.bpe.model",
            "special_tokens_map.json", "added_tokens.json", "vocab.json", "vocab.txt", "merges.txt", "generation_config.json",
            "preprocessor_config.json", "processor_config.json", "chat_template.json", "chat_template.jinja"]
        for path in files.keys where assets.contains(path) || isModelDocumentation(path)
            || (path.hasPrefix("chat_templates/") && path.hasSuffix(".jinja")) {
            selected.insert(path)
        }
        guard files["tokenizer_config.json"] != nil, files["tokenizer.json"] != nil else {
            throw AIModelRepositoryError.incomplete("缺少 tokenizer 與 tokenizer_config.json")
        }
        guard files["preprocessor_config.json"] != nil || files["processor_config.json"] != nil else {
            throw AIModelRepositoryError.incomplete("缺少視覺 processor 設定")
        }
        return selected.sorted().compactMap { files[$0] }
    }

    static func ggufFiles(in repository: AIHubRepository, mainPath: String,
                          projectorPath: String? = nil) throws -> [AIHubFile] {
        guard let main = repository.ggufModels.first(where: { $0.path == mainPath }) else {
            throw AIModelRepositoryError.incomplete("請選擇 GGUF 主模型")
        }
        let projector: AIHubFile
        if let projectorPath {
            guard let selected = repository.projectorFiles.first(where: { $0.path == projectorPath }) else {
                throw AIModelRepositoryError.incomplete("指定的 mmproj 不存在")
            }
            projector = selected
        } else {
            let sameFolder = repository.projectorFiles.filter { ($0.path as NSString).deletingLastPathComponent == (mainPath as NSString).deletingLastPathComponent }
            let candidates = sameFolder.isEmpty ? repository.projectorFiles : sameFolder
            guard candidates.count == 1 else {
                throw AIModelRepositoryError.incomplete(candidates.isEmpty ? "找不到視覺 mmproj" : "有多個 mmproj，請明確選擇配對檔案")
            }
            projector = candidates[0]
        }
        var result = [main]
        let expression = try NSRegularExpression(pattern: #"^(.*)-00001-of-(\d{5})\.gguf$"#, options: .caseInsensitive)
        if let match = expression.firstMatch(in: main.path, range: NSRange(main.path.startIndex..., in: main.path)),
           let prefixRange = Range(match.range(at: 1), in: main.path), let totalRange = Range(match.range(at: 2), in: main.path),
           let total = Int(main.path[totalRange]) {
            guard total >= 1, total <= 4096 else { throw AIModelRepositoryError.incomplete("GGUF 分片數量無效") }
            result = try (1...total).map { index in
                let path = String(main.path[prefixRange]) + String(format: "-%05d-of-%05d.gguf", index, total)
                guard let shard = repository.files.first(where: { $0.path.lowercased() == path.lowercased() }) else {
                    throw AIModelRepositoryError.incomplete(path)
                }
                return shard
            }
        }
        return result + [projector] + repository.files.filter { isModelDocumentation($0.path) }.sorted { $0.path < $1.path }
    }

    static func repositoryID(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("://") {
            guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.lowercased() == "huggingface.co",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
                throw AIModelRepositoryError.invalidRepository
            }
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw AIModelRepositoryError.invalidRepository
        }
        return value
    }

    static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"), !path.contains("\0"),
              !path.contains(where: { $0.isNewline }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AIModelRepositoryError.invalidPath(path)
        }
    }

    static func isProjector(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasSuffix(".gguf") && (name.contains("mmproj") || name.contains("vision-encoder") || name.contains("projector"))
    }

    private static func isModelDocumentation(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }
        return ["readme", "readme.md", "license", "license.md", "license.txt", "notice", "notice.md", "notice.txt",
                "copying", "copying.txt"].contains(path.lowercased())
    }

    static func isPrimaryGGUF(_ path: String) -> Bool {
        guard (try? validatePath(path)) != nil, path.lowercased().hasSuffix(".gguf"), !isProjector(path) else { return false }
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !["mtp-", "draft-", "dflash-"].contains(where: name.hasPrefix) else { return false }
        if let range = name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) {
            return name[range].hasPrefix("-00001-of-")
        }
        return true
    }

    private static func json(_ file: AIHubFile, session: URLSession) async throws -> [String: Any] {
        let data = try await read(file.url, session: session, limit: 16 * 1024 * 1024)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIModelRepositoryError.invalidResponse(file.path)
        }
        return json
    }

    private static func read(_ url: URL, session: URLSession, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("PhotoStyleApp/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIModelRepositoryError.invalidResponse("非 HTTP 回應") }
        guard response.statusCode == 200 else { throw AIModelRepositoryError.http(response.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw AIModelRepositoryError.invalidResponse("檔案清單過大") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw AIModelRepositoryError.invalidResponse("檔案清單過大") }
            data.append(byte)
        }
        return data
    }
}
