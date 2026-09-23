import Foundation
import PhotoStyleShared
import AppKit
import llama

enum PhotoStyleLLMRuntimeError: LocalizedError {
    case modelMissing(String)
    case modelLoadFailed(String, String)
    case projectorMissing(String)
    case projectorLoadFailed(String)
    case contextCreateFailed
    case imageEncodeFailed
    case imageDecodeFailed
    case imageTokenizationFailed(Int32)
    case generationFailed
    case grammarCreateFailed
    case invalidPrompt
    case promptTooLong(Int, Int)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let directory):
            "尚未安裝可用 AI 核心。模型目錄：\(directory)"
        case .modelLoadFailed(let fileName, let reason):
            "無法載入 AI 核心：\(fileName)。\(reason)"
        case .projectorMissing(let fileName):
            "缺少對應的 mmproj：\(fileName)"
        case .projectorLoadFailed(let fileName):
            "無法載入 mmproj：\(fileName)"
        case .contextCreateFailed:
            "無法建立 LLM 推論環境"
        case .imageEncodeFailed:
            "無法準備圖片給 LLM"
        case .imageDecodeFailed:
            "LLM 無法解讀圖片"
        case .imageTokenizationFailed(let code):
            "圖片 tokenization 失敗：\(code)"
        case .generationFailed:
            "LLM 產生參數失敗"
        case .grammarCreateFailed:
            "無法建立 AI 參數輸出格式，照片未變更。"
        case .invalidPrompt:
            "提示詞含有 NUL 控制字元，無法完整傳送給 AI。請移除該字元後再試，照片未變更。"
        case .promptTooLong(let count, let available):
            "提示詞與圖片需要 \(count) 個 token，超過可用的 \(available) 個 token。請縮短自訂提示詞。"
        case .invalidOutput(let output):
            "AI 回傳內容不是可解析的風格參數，照片未變更。請重試或調整提示詞。\n\(output.prefix(200))"
        }
    }
}

enum PhotoStyleAIProgress: Int, Sendable {
    case toneZones = 1
    case hdrCurve = 2
    case styleAndBackground = 3
    case skinRetouching = 4
    case postProcessing = 5
    case applyingPreview = 6
}

// Waiting for another inference must suspend without occupying a worker thread.
// Cancellation removes that waiter immediately, even while Metal is still busy.
actor PhotoStyleInferenceGate {
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    var waitingCount: Int { waiters.count }

    func acquire() async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !occupied {
                    occupied = true
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    // Execute outside the actor so long C/Metal calls cannot block cancellation
    // messages or the other callers waiting to enter this gate.
    nonisolated func withExclusiveAccess<T>(_ operation: () throws -> T) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
            let result = try operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}

// llama callbacks may run on C-created threads without a Swift Task context.
final class PhotoStyleInferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    static let loadProgressCallback: llama_progress_callback = { _, userData in
        guard let userData else { return true }
        return !Unmanaged<PhotoStyleInferenceCancellation>.fromOpaque(userData).takeUnretainedValue().isCancelled
    }

    static let abortCallback: ggml_abort_callback = { userData in
        guard let userData else { return false }
        return Unmanaged<PhotoStyleInferenceCancellation>.fromOpaque(userData).takeUnretainedValue().isCancelled
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}

final class PhotoStyleLLMRuntime {
    static let shared = PhotoStyleLLMRuntime()

    private let inferenceGate: PhotoStyleInferenceGate
    private var hasShutDown = false // Access only while holding inferenceGate.
    // llama's backend belongs to the process, not to an individual model cache.
    // Releasing one runtime must not tear down another runtime's active backend.
    private static let initializeBackend: Void = { llama_backend_init() }()
    private var loadedModel: OpaquePointer?
    private var loadedModelURL: URL?
    private var loadedModelFileIdentity: ModelFileIdentity?
    private var loadedModelUsesGPU = true
    private var loadedVisionContext: OpaquePointer?
    private var loadedVisionAuxURL: URL?
    private var loadedVisionFileIdentity: ModelFileIdentity?

    private struct ModelFileIdentity: Equatable {
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modificationDate = attributes[.modificationDate] as? Date
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    init(inferenceGate: PhotoStyleInferenceGate = PhotoStyleInferenceGate()) {
        self.inferenceGate = inferenceGate
    }

    deinit {
        if let loadedVisionContext {
            mtmd_free(loadedVisionContext)
        }
        if let loadedModel {
            llama_model_free(loadedModel)
        }
    }

    // Free the cached GGUF weights before the separate MLX worker allocates GPU memory.
    func unloadModel() async {
        try? await inferenceGate.withExclusiveAccess {
            self.releaseCachedModel()
        }
    }

    /// Drain in-flight C/Metal work before process-global ggml devices are freed.
    /// The caller must cancel active generation first. Late requests cannot reload.
    func shutdown() async {
        try? await inferenceGate.withExclusiveAccess {
            self.hasShutDown = true
            self.releaseCachedModel()
        }
    }

    private func releaseCachedModel() {
        if let context = loadedVisionContext { mtmd_free(context) }
        if let model = loadedModel { llama_model_free(model) }
        loadedVisionContext = nil
        loadedVisionAuxURL = nil
        loadedVisionFileIdentity = nil
        loadedModel = nil
        loadedModelURL = nil
        loadedModelFileIdentity = nil
    }

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
        guard stylePrompt?.contains("\0") != true else { throw PhotoStyleLLMRuntimeError.invalidPrompt }
        let cancellation = PhotoStyleInferenceCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try await self.inferenceGate.withExclusiveAccess {
                guard !self.hasShutDown else { throw CancellationError() }
                try cancellation.checkCancellation()
                guard let imageData = self.normalizedImageData(from: image) else {
                    throw PhotoStyleLLMRuntimeError.imageEncodeFailed
                }
                let plan = try self.generatePlan(
                    imageData: imageData,
                    style: style,
                    status: status,
                    stylePrompt: stylePrompt,
                    baseAdjustment: baseAdjustment,
                    progress: progress,
                    generatedText: generatedText,
                    cancellation: cancellation
                )
                try cancellation.checkCancellation()
                let usesCustomPrompt = PhotoStyleAIRequest.usesCustomPrompt(stylePrompt, style: style)
                let llmAdjustment = PhotoStyleAdjustmentMapper.adjustment(
                    from: plan, style: style, baseAdjustment: baseAdjustment, usesCustomPrompt: usesCustomPrompt
                )
                guard plan.editorControls == nil, !usesCustomPrompt, style == .autoDetection,
                      let imageAdjustment = PhotoStyleAdjustmentMapper.imageBasedAutoCorrection(for: image, baseAdjustment: baseAdjustment) else {
                    return llmAdjustment
                }
                return PhotoStyleAdjustmentMapper.mergeAutoDetectionAdjustment(llmAdjustment, with: imageAdjustment)
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await worker.value
                try Task.checkCancellation()
                return result
            } catch {
                // A native loader may fail while its cancellation callback fires.
                // Preserve cancellation instead of surfacing that incidental error.
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private func generatePlan(
        imageData: Data,
        style: PhotoStyle,
        status: AIModelStatus,
        stylePrompt: String?,
        baseAdjustment: StyleAdjustment,
        progress: (@Sendable (PhotoStyleAIProgress) -> Void)?,
        generatedText: (@Sendable (String) -> Void)?,
        cancellation: PhotoStyleInferenceCancellation
    ) throws -> PhotoStylePlan {
        try cancellation.checkCancellation()

        guard !status.activeModelFileName.isEmpty else {
            throw PhotoStyleLLMRuntimeError.modelMissing(status.modelDirectory.path)
        }

        let modelURL = status.modelDirectory.appendingPathComponent(status.activeModelFileName)
        let auxiliaryURL = try resolveAuxiliaryURL(modelURL: modelURL, status: status)
        let model = try loadModel(at: modelURL, cancellation: cancellation)
        try cancellation.checkCancellation()
        let visionContext = try loadVisionContext(modelURL: modelURL, model: model, auxiliaryURL: auxiliaryURL)
        try cancellation.checkCancellation()
        let prompt = try buildPrompt(style: style, model: model, stylePrompt: stylePrompt, baseAdjustment: baseAdjustment, imageData: imageData)
        let output = try generateVisionText(
            prompt: prompt,
            imageData: imageData,
            model: model,
            visionContext: visionContext,
            useGPU: loadedModelUsesGPU,
            maxTokens: Int32(PhotoStyleAIRequest.maxOutputTokens),
            progress: progress,
            cancellation: cancellation
        )

        try cancellation.checkCancellation()
        generatedText?(output)
        let plan = try Self.decodePlan(from: output)
        progress?(.applyingPreview)
        return plan
    }

    private func normalizedImageData(from image: PhotoImage) -> Data? {
        image.resizedForWebPreview(maxPixel: 1280).jpegData(compressionQuality: 0.88)
    }

    private func loadModel(at url: URL, cancellation: PhotoStyleInferenceCancellation) throws -> OpaquePointer {
        let identity = try ModelFileIdentity(url: url)
        if let loadedModel, loadedModelURL == url, loadedModelFileIdentity == identity {
            return loadedModel
        }

        _ = Self.initializeBackend

        if let loadedVisionContext {
            mtmd_free(loadedVisionContext)
            self.loadedVisionContext = nil
            loadedVisionAuxURL = nil
            loadedVisionFileIdentity = nil
        }
        if let loadedModel {
            llama_model_free(loadedModel)
            self.loadedModel = nil
            loadedModelURL = nil
            loadedModelFileIdentity = nil
            loadedModelUsesGPU = true
        }

        let attempts: [(name: String, params: llama_model_params, usesGPU: Bool)] = [
            ("GPU", modelParams(nGPU: 999, useMMap: true, cancellation: cancellation), true),
            ("CPU", modelParams(nGPU: 0, useMMap: true, cancellation: cancellation), false),
            ("CPU non-mmap", modelParams(nGPU: 0, useMMap: false, cancellation: cancellation), false)
        ]

        for attempt in attempts {
            try cancellation.checkCancellation()
            let candidate = withExtendedLifetime(cancellation) {
                url.path.withCString { llama_model_load_from_file($0, attempt.params) }
            }
            if let model = candidate {
                loadedModel = model
                loadedModelURL = url
                loadedModelFileIdentity = identity
                loadedModelUsesGPU = attempt.usesGPU
                return model
            }
            try cancellation.checkCancellation()
        }

        throw PhotoStyleLLMRuntimeError.modelLoadFailed(
            url.lastPathComponent,
            "已嘗試 GPU、CPU 與 non-mmap 載入仍失敗；可能是模型架構不受目前 llama.cpp 支援、檔案不完整，或裝置記憶體不足。"
        )
    }

    private func modelParams(nGPU: Int32, useMMap: Bool, cancellation: PhotoStyleInferenceCancellation) -> llama_model_params {
        var params = llama_model_default_params()
        params.n_gpu_layers = nGPU
        params.use_mmap = useMMap
        params.use_mlock = false
        params.progress_callback = PhotoStyleInferenceCancellation.loadProgressCallback
        params.progress_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        return params
    }

    private func loadVisionContext(
        modelURL: URL,
        model: OpaquePointer,
        auxiliaryURL: URL
    ) throws -> OpaquePointer {
        let identity = try ModelFileIdentity(url: auxiliaryURL)

        if let loadedVisionContext,
           loadedModelURL == modelURL,
           loadedVisionAuxURL == auxiliaryURL,
           loadedVisionFileIdentity == identity {
            return loadedVisionContext
        }

        if let loadedVisionContext {
            mtmd_free(loadedVisionContext)
            self.loadedVisionContext = nil
            loadedVisionAuxURL = nil
            loadedVisionFileIdentity = nil
        }

        var params = mtmd_context_params_default()
        params.use_gpu = loadedModelUsesGPU
        params.print_timings = false
        params.n_threads = inferenceThreadCount
        params.warmup = false

        let context = auxiliaryURL.path.withCString { path in
            mtmd_init_from_file(path, model, params)
        }

        guard let context else {
            throw PhotoStyleLLMRuntimeError.projectorLoadFailed(auxiliaryURL.lastPathComponent)
        }
        guard mtmd_support_vision(context) else {
            mtmd_free(context)
            throw PhotoStyleLLMRuntimeError.projectorLoadFailed(auxiliaryURL.lastPathComponent)
        }

        loadedVisionContext = context
        loadedVisionAuxURL = auxiliaryURL
        loadedVisionFileIdentity = identity
        return context
    }

    private func resolveAuxiliaryURL(modelURL: URL, status: AIModelStatus) throws -> URL {
        let directory = modelURL.deletingLastPathComponent()
        if let fileName = status.auxiliaryFileName, !fileName.isEmpty {
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PhotoStyleLLMRuntimeError.projectorMissing(fileName)
            }
            return url
        }

        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            let name = $0.lastPathComponent.lowercased()
            return $0.pathExtension.lowercased() == "gguf"
                && (name.contains("mmproj") || name.contains("vision-encoder") || name.contains("projector"))
        }

        guard !candidates.isEmpty else {
            throw PhotoStyleLLMRuntimeError.projectorMissing("mmproj-*.gguf")
        }

        if let paired = AIModelPairingResolver.bestAuxiliaryModelFile(forModel: modelURL, candidates: candidates) {
            return paired
        }

        return candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })[0]
    }

    private var inferenceThreadCount: Int32 {
        max(1, Int32(ProcessInfo.processInfo.processorCount / 2))
    }

    private func buildPrompt(style: PhotoStyle, model: OpaquePointer, stylePrompt: String?, baseAdjustment: StyleAdjustment, imageData: Data) throws -> String {
        guard let markerPointer = mtmd_default_marker() else {
            throw PhotoStyleLLMRuntimeError.generationFailed
        }
        let marker = String(cString: markerPointer)
        let systemInstruction = PhotoStyleAIRequest.systemInstruction
        let userContent = PhotoStyleAIRequest.userContent(style: style, prompt: stylePrompt, imageMarker: marker, baseAdjustment: baseAdjustment,
            imageAnalysis: PhotoImage(data: imageData).flatMap { PhotoStyleAdjustmentMapper.imageAnalysisSummary(for: $0) })

        if let templatePointer = llama_model_chat_template(model, nil),
           !String(cString: templatePointer).isEmpty,
           let formatted = applyChatTemplate(
            template: templatePointer,
            systemInstruction: systemInstruction,
            userContent: userContent
           ) {
            return formatted
        }

        return """
        System:
        \(systemInstruction)

        User:
        \(userContent)

        Assistant:
        """
    }

    private func generateVisionText(
        prompt: String,
        imageData: Data,
        model: OpaquePointer,
        visionContext: OpaquePointer,
        useGPU: Bool,
        maxTokens: Int32,
        progress: (@Sendable (PhotoStyleAIProgress) -> Void)?,
        cancellation: PhotoStyleInferenceCancellation
    ) throws -> String {
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(PhotoStyleAIRequest.contextLimit)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_seq_max = 1
        contextParams.n_threads = inferenceThreadCount
        contextParams.n_threads_batch = contextParams.n_threads
        contextParams.offload_kqv = useGPU
        contextParams.abort_callback = PhotoStyleInferenceCancellation.abortCallback
        contextParams.abort_callback_data = Unmanaged.passUnretained(cancellation).toOpaque()

        guard let context = llama_init_from_model(model, contextParams) else {
            throw PhotoStyleLLMRuntimeError.contextCreateFailed
        }
        defer {
            llama_free(context)
            withExtendedLifetime(cancellation) {}
        }
        try cancellation.checkCancellation()

        let bitmap: OpaquePointer? = imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return mtmd_helper_bitmap_init_from_buf(visionContext, baseAddress, imageData.count)
        }
        guard let bitmap else {
            throw PhotoStyleLLMRuntimeError.imageDecodeFailed
        }
        defer { mtmd_bitmap_free(bitmap) }

        "photo-style-source".withCString { id in
            mtmd_bitmap_set_id(bitmap, id)
        }

        guard let inputChunks = mtmd_input_chunks_init() else {
            throw PhotoStyleLLMRuntimeError.imageTokenizationFailed(-1)
        }
        defer { mtmd_input_chunks_free(inputChunks) }

        let tokenizationResult = prompt.withCString { promptCString in
            var text = mtmd_input_text(text: promptCString, add_special: true, parse_special: true)
            var bitmapPointer: OpaquePointer? = bitmap
            return withUnsafeMutablePointer(to: &bitmapPointer) { bitmapListPointer in
                mtmd_tokenize(visionContext, inputChunks, &text, bitmapListPointer, 1)
            }
        }
        guard tokenizationResult == 0 else {
            throw PhotoStyleLLMRuntimeError.imageTokenizationFailed(tokenizationResult)
        }

        let promptTokens = mtmd_helper_get_n_tokens(inputChunks)
        let availableTokens = Int(contextParams.n_ctx) - Int(maxTokens)
        guard promptTokens <= availableTokens else {
            throw PhotoStyleLLMRuntimeError.promptTooLong(promptTokens, availableTokens)
        }
        try cancellation.checkCancellation()

        var newPast: llama_pos = 0
        let evalResult = mtmd_helper_eval_chunks(
            visionContext,
            context,
            inputChunks,
            0,
            0,
            Int32(contextParams.n_batch),
            true,
            &newPast
        )
        try cancellation.checkCancellation()
        guard evalResult == 0 else {
            throw PhotoStyleLLMRuntimeError.generationFailed
        }

        return try generateSampledText(
            context: context,
            model: model,
            maxTokens: maxTokens,
            progress: progress,
            cancellation: cancellation
        )
    }

    private func generateSampledText(
        context: OpaquePointer,
        model: OpaquePointer,
        maxTokens: Int32,
        progress: (@Sendable (PhotoStyleAIProgress) -> Void)?,
        cancellation: PhotoStyleInferenceCancellation
    ) throws -> String {
        guard let vocab = llama_model_get_vocab(model) else {
            throw PhotoStyleLLMRuntimeError.generationFailed
        }

        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw PhotoStyleLLMRuntimeError.generationFailed
        }
        defer { llama_sampler_free(sampler) }
        let grammar = PhotoStyleAIRequest.grammar.withCString { grammar in
            "root".withCString { root in llama_sampler_init_grammar(vocab, grammar, root) }
        }
        guard let grammar else { throw PhotoStyleLLMRuntimeError.grammarCreateFailed }
        llama_sampler_chain_add(sampler, grammar)
        guard let greedySampler = llama_sampler_init_greedy() else {
            throw PhotoStyleLLMRuntimeError.generationFailed
        }
        llama_sampler_chain_add(sampler, greedySampler)

        var generatedBytes: [UInt8] = []
        var braceDepth = 0
        var jsonStarted = false
        var inString = false
        var escaped = false
        var lastProgressRawValue = 0

        for _ in 0..<maxTokens {
            try cancellation.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            // llama_sampler_sample already accepts the token, including grammar state.

            if llama_vocab_is_eog(vocab, token) {
                break
            }

            let piece = tokenToPieceBytes(token, vocab: vocab)
            generatedBytes.append(contentsOf: piece)
            // A token may end halfway through a Chinese UTF-8 character. Decode
            // the accumulated bytes so the next token can finish that character.
            let generated = String(decoding: generatedBytes, as: UTF8.self)
            if let generatedProgress = generatedProgress(in: generated),
               generatedProgress.rawValue > lastProgressRawValue {
                lastProgressRawValue = generatedProgress.rawValue
                progress?(generatedProgress)
            }
            for ch in piece {
                if escaped { escaped = false; continue }
                if ch == 0x5C && inString { escaped = true; continue }
                if ch == 0x22 { inString.toggle(); continue }
                if inString { continue }
                if ch == 0x7B {
                    jsonStarted = true
                    braceDepth += 1
                } else if ch == 0x7D {
                    braceDepth -= 1
                }
            }

            if jsonStarted && braceDepth <= 0 { break }
            try cancellation.checkCancellation()
            var nextToken = token
            let batch = llama_batch_get_one(&nextToken, 1)
            let decodeResult = llama_decode(context, batch)
            try cancellation.checkCancellation()
            guard decodeResult == 0 else {
                throw PhotoStyleLLMRuntimeError.generationFailed
            }
        }

        return String(decoding: generatedBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generatedProgress(in output: String) -> PhotoStyleAIProgress? {
        if output.contains("post_processing") {
            return .postProcessing
        }
        if output.contains("skin_whitening") || output.contains("skin_smoothing") {
            return .skinRetouching
        }
        if output.contains("background_blur") || output.contains("\"strength\"") {
            return .styleAndBackground
        }
        if output.contains("hdr_tone_curve") {
            return .hdrCurve
        }
        if output.contains("tone_zones") {
            return .toneZones
        }
        return nil
    }

    private func tokenToPieceBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = Array<CChar>(repeating: 0, count: 64)
        let pieceLength = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if pieceLength < 0 {
            buffer = Array<CChar>(repeating: 0, count: Int(abs(pieceLength)) + 1)
            let retryLength = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
            guard retryLength >= 0 else { return [] }
            return buffer.prefix(Int(retryLength)).map { UInt8(bitPattern: $0) }
        }
        return buffer.prefix(Int(pieceLength)).map { UInt8(bitPattern: $0) }
    }

    private func applyChatTemplate(
        template: UnsafePointer<CChar>,
        systemInstruction: String,
        userContent: String
    ) -> String? {
        if let prompt = Self.gemma4ChatPrompt(
            template: String(cString: template), systemInstruction: systemInstruction, userContent: userContent
        ) {
            return prompt
        }
        return systemInstruction.withCString { systemPointer in
            userContent.withCString { userPointer in
                "system".withCString { systemRole in
                    "user".withCString { userRole in
                        var messages = [
                            llama_chat_message(role: systemRole, content: systemPointer),
                            llama_chat_message(role: userRole, content: userPointer)
                        ]
                        var buffer = Array<CChar>(repeating: 0, count: max((systemInstruction.utf8.count + userContent.utf8.count) * 4, 4096))
                        let applied = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                        if applied < 0 {
                            return nil
                        }
                        if Int(applied) >= buffer.count {
                            buffer = Array<CChar>(repeating: 0, count: Int(applied) + 1)
                            let retried = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                            guard retried >= 0 else { return nil }
                            return String(decoding: buffer.prefix(Int(retried)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        }
                        return String(decoding: buffer.prefix(Int(applied)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
            }
        }
    }

    // The C API only recognizes a fixed set of templates. Gemma 4's GGUF uses
    // different turn markers from Gemma 1–3, so its plain text conversation must
    // follow the no-tools, thinking-disabled branch of that embedded template.
    static func gemma4ChatPrompt(template: String, systemInstruction: String, userContent: String) -> String? {
        guard template.contains("<|turn>"), template.contains("<turn|>") else { return nil }
        return "<|turn>system\n\(systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n<|turn>user\n\(userContent.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n<|turn>model\n"
    }

    static func decodePlan(from output: String) throws -> PhotoStylePlan {
        do {
            return try PhotoStylePlanJSONDecoder.decodeGeneratedPlan(from: output)
        } catch {
            throw PhotoStyleLLMRuntimeError.invalidOutput(output)
        }
    }
}
