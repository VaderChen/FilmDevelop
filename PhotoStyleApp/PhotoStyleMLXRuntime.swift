import AppKit
import Foundation
import PhotoStyleShared

/// A request owns one native MLX subprocess, including its Metal allocations.
/// No HTTP endpoint, Python installation, or other application's files are used.
final class PhotoStyleMLXRuntime: @unchecked Sendable {
    static let shared = PhotoStyleMLXRuntime()
    private let gate = PhotoStyleInferenceGate()

    static var executableURL: URL? { AIModelRuntimeSupport.executableURL }
    static var isAvailable: Bool { AIModelRuntimeSupport.isAvailable }
    static var availabilityMessage: String { AIModelRuntimeSupport.availabilityMessage }

    func generateAdjustment(
        image: PhotoImage,
        style: PhotoStyle,
        baseAdjustment: StyleAdjustment,
        status: AIModelStatus,
        stylePrompt: String? = nil,
        progress: (@Sendable (PhotoStyleAIProgress) -> Void)? = nil,
        generatedText: (@Sendable (String) -> Void)? = nil
    ) async throws -> StyleAdjustment {
        try Task.checkCancellation()
        if !Self.isAvailable { throw PhotoStyleMLXError.unavailable(Self.availabilityMessage) }
        guard stylePrompt?.contains("\0") != true else { throw PhotoStyleLLMRuntimeError.invalidPrompt }
        guard status.family == "mlx", !status.activeModelFileName.isEmpty, let executable = Self.executableURL else {
            throw PhotoStyleMLXError.unavailable("尚未選取可用的 MLX 視覺模型。")
        }
        guard FileManager.default.isReadableFile(atPath: executable.deletingLastPathComponent()
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib").path) else {
            throw PhotoStyleMLXError.unavailable("MLX Metal 函式庫缺失，請重新建置執行核心。")
        }
        try await gate.acquire()
        do {
            let result = try await generateOwnedRequest(
                executable: executable, image: image, style: style,
                baseAdjustment: baseAdjustment, status: status, stylePrompt: stylePrompt,
                progress: progress, generatedText: generatedText)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func generateOwnedRequest(
        executable: URL, image: PhotoImage, style: PhotoStyle,
        baseAdjustment: StyleAdjustment, status: AIModelStatus, stylePrompt: String?,
        progress: (@Sendable (PhotoStyleAIProgress) -> Void)?,
        generatedText: (@Sendable (String) -> Void)?
    ) async throws -> StyleAdjustment {
        let operation = PhotoStyleMLXProcess()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let jpeg = image.resizedForWebPreview(maxPixel: 1280).jpegData(compressionQuality: 0.88) else {
                throw PhotoStyleLLMRuntimeError.imageEncodeFailed
            }
            let request = PhotoStyleMLXRequest(
                modelDirectory: status.modelDirectory.appendingPathComponent(status.activeModelFileName).path,
                systemPrompt: PhotoStyleAIRequest.systemInstruction,
                userPrompt: PhotoStyleAIRequest.userContent(style: style, prompt: stylePrompt, imageMarker: "", baseAdjustment: baseAdjustment,
                    imageAnalysis: PhotoImage(data: jpeg).flatMap { PhotoStyleAdjustmentMapper.imageAnalysisSummary(for: $0) }),
                imageBase64: jpeg.base64EncodedString(), maxTokens: PhotoStyleAIRequest.maxOutputTokens, contextLimit: PhotoStyleAIRequest.contextLimit)
            progress?(.toneZones)
            let response = try operation.run(executable: executable, request: JSONEncoder().encode(request))
            try Task.checkCancellation()
            generatedText?(response.text ?? "")
            // MLX does not implement GGUF's GBNF constraint. A complete, valid
            // plan is mandatory; malformed output never changes the photograph.
            let plan = try PhotoStyleLLMRuntime.decodePlan(from: response.text ?? "")
            let customized = PhotoStyleAIRequest.usesCustomPrompt(stylePrompt, style: style)
            let adjustment = PhotoStyleAdjustmentMapper.adjustment(
                from: plan, style: style, baseAdjustment: baseAdjustment, usesCustomPrompt: customized)
            progress?(.applyingPreview)
            if plan.editorControls == nil, !customized, style == .autoDetection,
               let automatic = PhotoStyleAdjustmentMapper.imageBasedAutoCorrection(for: image, baseAdjustment: baseAdjustment) {
                return PhotoStyleAdjustmentMapper.mergeAutoDetectionAdjustment(adjustment, with: automatic)
            }
            return adjustment
        }
        return try await withTaskCancellationHandler {
            do {
                let value = try await worker.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            operation.cancel()
            worker.cancel()
        }
    }
}

private struct PhotoStyleMLXRequest: Encodable {
    let modelDirectory: String
    let systemPrompt: String
    let userPrompt: String
    let imageBase64: String
    let maxTokens: Int
    let contextLimit: Int
}

private struct PhotoStyleMLXResponse: Decodable {
    let text: String?
    let error: String?
}

private enum PhotoStyleMLXError: LocalizedError {
    case unavailable(String), failed(String), timeout, outputLimit
    var errorDescription: String? {
        switch self {
        case .unavailable(let text): return text
        case .failed(let text): return "MLX 分析失敗，照片未變更。\(text)"
        case .timeout: return "MLX 分析超過 5 分鐘，已停止運算，照片未變更。"
        case .outputLimit: return "MLX 回傳內容超過安全長度，已停止運算，照片未變更。"
        }
    }
}

/// Pipe readers always drain concurrently; large stderr output cannot deadlock
/// a worker. All retained data is bounded, even while the GPU is loading.
private final class PhotoStyleMLXProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var overflow = false
    private var output = Data()
    private var diagnostic = Data()
    private let limit = 256 * 1024

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func run(executable: URL, request: Data) throws -> PhotoStyleMLXResponse {
        guard request.count <= 16 * 1024 * 1024 else { throw PhotoStyleMLXError.outputLimit }
        let child = Process()
        child.executableURL = executable
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        // Hugging Face loading remains local even if a checkpoint references
        // remote assets. Missing tokenizer/model files must produce an error.
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        child.environment = environment
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoStyleMLXRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        environment["TMPDIR"] = temporary.path + "/"
        child.environment = environment
        let input = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = input
        child.standardOutput = stdout
        child.standardError = stderr
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch {
            process = nil
            lock.unlock()
            throw error
        }
        lock.unlock()
        let readers = DispatchGroup()
        for (handle, isOutput) in [(stdout.fileHandleForReading, true), (stderr.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); readers.leave() }
                while let data = try? handle.read(upToCount: 16 * 1024), !data.isEmpty {
                    self.lock.lock()
                    if isOutput {
                        if self.output.count + data.count > self.limit {
                            self.overflow = true
                            if child.isRunning { child.terminate() }
                        } else { self.output.append(data) }
                    } else {
                        self.diagnostic.append(data)
                        if self.diagnostic.count > self.limit { self.diagnostic.removeFirst(self.diagnostic.count - self.limit) }
                    }
                    self.lock.unlock()
                }
            }
        }
        // Child reads stdin before loading the model; closing stdin terminates
        // exactly one request and prevents accidental multiple commands.
        do { try input.fileHandleForWriting.write(contentsOf: request) } catch {
            if child.isRunning { child.terminate() }
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(300)
        var stoppingSince: Date?
        var timedOut = false
        while child.isRunning {
            lock.lock()
            let shouldStop = cancelled || overflow
            lock.unlock()
            if shouldStop || Date() >= deadline {
                timedOut = !shouldStop
                if stoppingSince == nil {
                    stoppingSince = Date()
                    if child.isRunning { child.terminate() }
                } else if Date().timeIntervalSince(stoppingSince!) > 2, child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.waitUntilExit()
        readers.wait()
        lock.lock()
        process = nil
        let wasCancelled = cancelled, exceeded = overflow
        let bytes = output, diagnosticBytes = diagnostic
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if timedOut { throw PhotoStyleMLXError.timeout }
        if exceeded { throw PhotoStyleMLXError.outputLimit }
        let response = try? JSONDecoder().decode(PhotoStyleMLXResponse.self, from: bytes)
        if let message = response?.error { throw PhotoStyleMLXError.failed(String(message.prefix(1000))) }
        guard child.terminationStatus == 0, let response, let text = response.text, !text.isEmpty else {
            let message = String(decoding: diagnosticBytes.suffix(2000), as: UTF8.self)
            throw PhotoStyleMLXError.failed(message.isEmpty ? "本機執行核心未回傳有效結果。" : message)
        }
        return response
    }
}
