import Foundation
import MLX
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

private struct Request: Decodable {
    let modelDirectory: String
    let systemPrompt: String
    let userPrompt: String
    let imageBase64: String
    let maxTokens: Int
    let contextLimit: Int
}

private struct Response: Encodable {
    var text: String?
    var error: String?
}

private struct WorkerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One process, one local model, one request. The parent owns cancellation and
/// termination. Its strict plan decoder validates the generated text before use.
@main enum PhotoStyleMLXWorker {
    static func main() async {
        // Reserve the original stdout for protocol JSON. Third-party diagnostics
        // printed to stdout are redirected to stderr before initializing MLX.
        let responseFD = dup(STDOUT_FILENO)
        guard responseFD >= 0 else { exit(1) }
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let destination = FileHandle(fileDescriptor: responseFD, closeOnDealloc: true)
        let response: Response
        do {
            var bytes = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard bytes.count + chunk.count <= 16 * 1024 * 1024 else {
                    throw WorkerError(message: "MLX 請求過大。")
                }
                bytes.append(chunk)
            }
            let request = try JSONDecoder().decode(Request.self, from: bytes)
            response = Response(text: try await generate(request), error: nil)
        } catch {
            response = Response(text: nil, error: String(error.localizedDescription.prefix(2000)))
        }
        do { try destination.write(contentsOf: JSONEncoder().encode(response)) }
        catch { exit(1) }
        exit(response.error == nil ? 0 : 1)
    }

    private static func generate(_ request: Request) async throws -> String {
        guard request.modelDirectory.hasPrefix("/"),
              !request.systemPrompt.contains("\0"), !request.userPrompt.contains("\0"),
              (1...4096).contains(request.maxTokens),
              (4096...16384).contains(request.contextLimit),
              request.systemPrompt.utf8.count + request.userPrompt.utf8.count <= 128 * 1024 else {
            throw WorkerError(message: "MLX 請求參數無效。")
        }
        let directory = URL(fileURLWithPath: request.modelDirectory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(name).path) else {
                throw WorkerError(message: "MLX 模型缺少本機檔案：\(name)")
            }
        }
        guard let image = Data(base64Encoded: request.imageBase64), image.count <= 10 * 1024 * 1024 else {
            throw WorkerError(message: "MLX 圖片資料無效或過大。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoStyleMLX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let imageURL = temporary.appendingPathComponent("input.jpg")
        try image.write(to: imageURL, options: .atomic)
        // Upstream scans every *.safetensors recursively, including macOS
        // AppleDouble files. Expose a clean symlink view without modifying or
        // duplicating the user's model files.
        let modelView = temporary.appendingPathComponent("model", isDirectory: true)
        try createModelView(source: directory, destination: modelView)
        fputs("MLX loading local vision model\n", stderr)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelView, using: #huggingFaceTokenizerLoader())
        let input = UserInput(
            chat: [.system(request.systemPrompt), .user(request.userPrompt, images: [.url(imageURL)])],
            additionalContext: ["enable_thinking": false, "reasoning_effort": "low"])
        let prepared = try await container.prepare(input: input)
        let promptTokens = prepared.text.tokens.dim(-1)
        guard promptTokens + request.maxTokens <= request.contextLimit else {
            throw WorkerError(message: "圖片與提示詞超過 MLX 上下文上限，請縮短提示詞。")
        }
        fputs("MLX generating prompt_tokens=\(promptTokens)\n", stderr)
        let stream = try await container.generate(
            input: prepared,
            parameters: GenerateParameters(maxTokens: request.maxTokens, temperature: 0, prefillStepSize: 256))
        var result = ""
        for await event in stream {
            try Task.checkCancellation()
            if case .chunk(let text) = event {
                result += text
                guard result.utf8.count <= 128 * 1024 else { throw WorkerError(message: "MLX 輸出過長。") }
            }
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerError(message: "MLX 未產生可用回應。")
        }
        return result
    }

    private static func createModelView(source: URL, destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        guard let files = manager.enumerator(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { throw WorkerError(message: "無法讀取 MLX 模型目錄。") }
        var count = 0
        for case let file as URL in files {
            count += 1
            guard count <= 4096 else { throw WorkerError(message: "MLX 模型目錄包含過多檔案。") }
            // FileManager may enumerate /var as /private/var even after URL
            // standardization. Depth supplies the relative path without a
            // fragile textual root-prefix comparison.
            let components = Array(file.pathComponents.suffix(files.level))
            let relative = components.joined(separator: "/")
            guard !components.isEmpty, components.count <= 12,
                  !components.contains(where: { $0.hasPrefix(".") }) else {
                files.skipDescendants(); continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                if values.isSymbolicLink == true { files.skipDescendants(); continue }
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true || values.isSymbolicLink == true {
                try manager.createSymbolicLink(at: target, withDestinationURL: file)
            }
        }
    }

}
