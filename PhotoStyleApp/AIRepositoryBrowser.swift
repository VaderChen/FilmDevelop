import Foundation
import Combine
import CryptoKit

struct AIRepositoryBrowserState {
    var query = ""
    var format = "mlx"
    var loading = false
    var message = "搜尋模型名稱，或貼上 Hugging Face 的 owner/repository。"
    var results: [AIHubSearchResult] = []
    var repository: AIHubRepository?
    var mlxFiles: [AIHubFile] = []
}

/// Network discovery never changes the active model or starts a weight download.
final class AIRepositoryBrowser: ObservableObject {
    @Published private(set) var state = AIRepositoryBrowserState()
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    deinit { task?.cancel() }

    func search(_ query: String, format: String) {
        begin(query, format: format)
        let id = requestID
        task = Task { @MainActor [weak self] in
            do {
                let results = try await AIModelRepositoryClient.search(query: query, format: format)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.state.results = results
                self.state.loading = false
                self.state.message = results.isEmpty ? "沒有找到模型；可直接輸入 repository 位址。" : "選擇一個模型以查看下載檔案。"
            } catch { self?.finish(error, id: id) }
        }
    }

    func inspect(_ input: String, format: String) {
        begin(input, format: format)
        let id = requestID
        task = Task { @MainActor [weak self] in
            do {
                let repository = try await AIModelRepositoryClient.inspect(input)
                let files = format == "mlx" ? try await AIModelRepositoryClient.mlxFiles(in: repository) : []
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.state.repository = repository
                self.state.mlxFiles = files
                self.state.loading = false
                self.state.message = format == "mlx" ? "將下載完整 MLX 模型與影像處理、分詞設定。" : "請選擇 GGUF 主模型及相容的 mmproj。"
            } catch { self?.finish(error, id: id) }
        }
    }

    func cancel() {
        task?.cancel()
        requestID = UUID()
        state.loading = false
        state.message = "已取消查詢。"
    }

    private func begin(_ query: String, format: String) {
        task?.cancel()
        requestID = UUID()
        state = AIRepositoryBrowserState(query: query, format: format == "gguf" ? "gguf" : "mlx", loading: true,
                                         message: "正在查詢 Hugging Face…")
    }

    private func finish(_ error: Error, id: UUID) {
        guard requestID == id else { return }
        state.loading = false
        state.message = error is CancellationError ? "已取消查詢。" : error.localizedDescription
    }

    func downloadPlan(mainPath: String?, projectorPath: String?) throws -> (AIHubRepository, [AIHubFile]) {
        guard !state.loading, let repository = state.repository else {
            throw AIModelError.invalidURL("請先查詢模型 repository")
        }
        if state.format == "mlx" {
            guard !state.mlxFiles.isEmpty else { throw AIModelError.modelMissing(repository.id) }
            return (repository, state.mlxFiles)
        }
        guard let mainPath, let projectorPath, !projectorPath.isEmpty else {
            throw AIModelError.auxiliaryMissing(repository.id)
        }
        return (repository, try AIModelRepositoryClient.ggufFiles(in: repository, mainPath: mainPath, projectorPath: projectorPath))
    }

    static func directoryName(repository: AIHubRepository, files: [AIHubFile]) -> String {
        let identity = repository.id + "@" + repository.revision + ":" + files.map(\.path).sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let title = repository.id.replacingOccurrences(of: "/", with: "--")
        return String(title.prefix(100)) + "-" + digest
    }

    func payload() -> [String: Any] {
        func file(_ item: AIHubFile) -> [String: Any] {
            ["path": item.path, "size": item.size ?? 0]
        }
        let repository = state.repository
        return [
            "query": state.query, "format": state.format, "loading": state.loading, "message": state.message,
            "results": state.results.map { ["id": $0.id, "downloads": $0.downloads] as [String: Any] },
            "id": repository?.id ?? "", "revision": repository?.revision ?? "",
            "mainFiles": repository?.ggufModels.map(file) ?? [],
            "projectorFiles": repository?.projectorFiles.map(file) ?? [],
            "files": state.mlxFiles.map(file),
            "totalBytes": state.mlxFiles.reduce(0.0) { $0 + Double($1.size ?? 0) }
        ]
    }
}
