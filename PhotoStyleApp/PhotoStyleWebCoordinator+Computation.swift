import AppKit

struct PhotoStyleComputationRequest: Sendable {
    let image: PhotoImage
    let style: PhotoStyle
    let baseAdjustment: StyleAdjustment
    let status: AIModelStatus
    let stylePrompt: String
}

protocol PhotoStyleComputing: Sendable {
    func generate(_ request: PhotoStyleComputationRequest,
                  progress: @escaping @Sendable (PhotoStyleAIProgress) -> Void) async throws -> StyleAdjustment
}

struct LocalPhotoStyleComputer: PhotoStyleComputing {
    func generate(_ request: PhotoStyleComputationRequest,
                  progress: @escaping @Sendable (PhotoStyleAIProgress) -> Void) async throws -> StyleAdjustment {
        if request.status.family == "mlx" {
            await PhotoStyleLLMRuntime.shared.unloadModel()
            return try await PhotoStyleMLXRuntime.shared.generateAdjustment(
                image: request.image, style: request.style, baseAdjustment: request.baseAdjustment,
                status: request.status, stylePrompt: request.stylePrompt, progress: progress
            )
        }
        return try await PhotoStyleLLMRuntime.shared.generateAdjustment(
            image: request.image, style: request.style, baseAdjustment: request.baseAdjustment,
            status: request.status, stylePrompt: request.stylePrompt, progress: progress
        )
    }
}

extension PhotoStyleWebCoordinator {
    var canCancelComputation: Bool {
        isComputing && !isCancellingComputation && computationCompletedItemCount < Self.aiComputationItems.count
    }

    func cancelStyleComputation() {
        guard canCancelComputation else { return }
        isCancellingComputation = true
        inferenceTask?.cancel()
        computationStep = "正在取消，等待目前運算結束"
        sendState(includeImages: false)
    }

    // Native menu/toolbar commands first commit the WebKit editor's pending values.
    // The resulting bridge message calls runStyleComputation directly, without a loop.
    func requestStyleComputation() {
        guard canCompute else { return }
        if isWebReady, webView != nil {
            showPage("runAI")
        } else {
            runStyleComputation()
        }
    }

    func runStyleComputation() {
        runStyleComputation(promptOverride: nil, languageOverride: nil)
    }

    func runStyleComputation(promptOverride: String?, languageOverride: String?) {
        guard selectedStyle != .original, !isTerminating, let sourceImage, let previewImage, !isComputing, !isSavingImage, !isLoadingImage else { return }
        guard aiModelStore.status.ready, !aiModelStore.isBusy else {
            sendToast(aiModelStore.status.message)
            return
        }

        let id = UUID()
        computationID = id
        isComputing = true
        isCancellingComputation = false
        computationCompletedItemCount = 0
        computationStep = Self.aiComputationItems[0]
        lastMessage = ""
        sendState(includeImages: false)

        let style = selectedStyle
        let baseAdjustment = adjustmentStore.adjustment(for: style)
        let status = aiModelStore.status
        // Snapshot the effective prompt before work starts; later UI language changes
        // affect the next analysis only. MCP overrides never alter saved preferences.
        let language = StylePromptStore.normalizedLanguage(languageOverride ?? promptLanguage)
        let stylePrompt = promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? stylePromptStore.prompt(for: style, language: language)
        let computer = computer
        let renderer = renderer
        let existingSubjectMask = sourceSubjectMask

        inferenceTask = Task { @MainActor [weak self] in
            do {
                let analysisImage = await Task.detached(priority: .userInitiated) {
                    // The AI can now change crop geometry; it must see the full source.
                    sourceImage.resizedForWebPreview(maxPixel: 800)
                }.value
                try Task.checkCancellation()
                let request = PhotoStyleComputationRequest(image: analysisImage, style: style,
                    baseAdjustment: baseAdjustment, status: status, stylePrompt: stylePrompt)
                let computed = try await computer.generate(request, progress: { [weak self] progress in
                    DispatchQueue.main.async {
                        guard let self, self.computationID == id else { return }
                        self.updateComputationProgress(progress)
                    }
                })
                // A backend may finish its current C/Metal call after cancellation.
                // Never commit that result to the image or adjustment store.
                try Task.checkCancellation()
                guard let self, self.computationID == id else { return }
                // Segmentation belongs to this explicit analysis. Keep it provisional
                // so cancelling cannot alter the current photo or its preview.
                var subjectMask = existingSubjectMask
                if subjectMask == nil, renderer.canDetectSubjectMask {
                    self.computationStep = "偵測主體並準備預覽"
                    self.sendState(includeImages: false)
                    subjectMask = await Task.detached(priority: .userInitiated) {
                        renderer.detectSubjectMask(for: previewImage)
                    }.value
                    try Task.checkCancellation()
                    guard self.computationID == id else { return }
                }
                self.sourceSubjectMask = subjectMask
                self.adjustmentStore.setAdjustment(computed, for: style)
                self.applySelectedStyle()
                self.computationCompletedItemCount = Self.aiComputationItems.count
                self.computationStep = "計算完成"
                self.shouldExpandAdjustmentsAfterComputation = true
                self.sendState(includeImages: false)
                await self.waitForPreviewRender()
                self.lastMessage = "AI 分析完成。"
                self.finishComputation(id: id)
            } catch {
                guard let self, self.computationID == id else { return }
                let wasCancelled = self.isCancellingComputation || error is CancellationError
                self.finishComputation(id: id)
                self.sendToast(wasCancelled ? "已取消 AI 分析，照片未變更。" : error.localizedDescription)
            }
        }
    }

    private func finishComputation(id: UUID) {
        guard computationID == id else { return }
        computationID = nil
        inferenceTask = nil
        isComputing = false
        isCancellingComputation = false
        computationStep = ""
        computationCompletedItemCount = 0
        sendState(includeImages: false)
    }

    private func updateComputationProgress(_ progress: PhotoStyleAIProgress) {
        guard isComputing, !isCancellingComputation,
              progress.rawValue > computationCompletedItemCount else { return }
        computationCompletedItemCount = progress.rawValue
        let activeIndex = min(progress.rawValue, Self.aiComputationItems.count - 1)
        computationStep = Self.aiComputationItems[activeIndex]
        sendState(includeImages: false)
    }
}
