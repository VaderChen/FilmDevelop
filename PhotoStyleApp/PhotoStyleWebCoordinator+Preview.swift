import AppKit

struct PhotoStylePreviewJob {
    let revision: UInt64
    let request: PhotoStyleRenderRequest
    let cacheKey: String?
    let maskDetectionImage: PhotoImage
}

extension PhotoStyleWebCoordinator {
    // 拖曳只渲染顯示預覽，結束後才將最新參數套用到處理圖。
    func beginAdjustmentPreview(_ payload: [String: Any]) {
        guard sourceImage != nil, !isTerminating, !isLoadingImage, !isComputing, !isSavingImage, !isMCPMutating,
              payload["photoGeneration"] as? String == photoGeneration.uuidString,
              payload["style"] as? String == selectedStyle.rawValue,
              let id = payload["interactionID"] as? String, !id.isEmpty else { return }
        let needsMask = adjustmentPreviewNeedsMask || pendingPreviewRender?.request.shouldDetectSubjectMask == true
        cancelAdjustmentPreview()
        adjustmentPreviewNeedsMask = needsMask
        adjustmentPreviewInteractionID = id
        // 已在執行的舊處理圖無法中途停止，但不可再覆蓋新的拖曳預覽。
        previewRevision &+= 1
        pendingPreviewRender = nil
        updateActionAvailability()
    }

    func acceptsAdjustmentPreview(_ payload: [String: Any]) -> Bool {
        guard let id = payload["interactionID"] as? String else { return false }
        return id == adjustmentPreviewInteractionID
            && payload["photoGeneration"] as? String == photoGeneration.uuidString
            && payload["style"] as? String == selectedStyle.rawValue
    }

    func endAdjustmentPreview(_ payload: [String: Any]) {
        guard acceptsAdjustmentPreview(payload) else { return }
        adjustmentPreviewInteractionID = nil
        delayedProcessingRender?.cancel()
        let generation = UUID()
        adjustmentPreviewGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.adjustmentPreviewGeneration == generation else { return }
            self.delayedProcessingRender = nil
            guard !self.isTerminating, !self.isLoadingImage, !self.isComputing, !self.isSavingImage else {
                self.cancelAdjustmentPreview()
                self.finishPreviewWaiters()
                return
            }
            self.applySelectedStyle()
            self.sendState(includeImages: true)
        }
        delayedProcessingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.adjustmentSettleDelay, execute: work)
        updateActionAvailability()
    }

    func cancelAdjustmentPreview() {
        filmHoverPreview.cancel(clearCache: true)
        delayedProcessingRender?.cancel()
        delayedProcessingRender = nil
        adjustmentPreviewInteractionID = nil
        adjustmentPreviewNeedsMask = false
        adjustmentPreviewGeneration = UUID()
    }

    func commitAdjustmentPreview() {
        guard adjustmentPreviewInteractionID != nil || delayedProcessingRender != nil else { return }
        applySelectedStyle()
        sendState(includeImages: true)
    }

    /// Only the active render and the latest pending request are retained.
    /// All mutable coordinator state stays on the main queue; the worker receives a snapshot.
    func enqueuePreviewRender(_ request: PhotoStyleRenderRequest) {
        filmHoverPreview.cancel(clearCache: true)
        // A newer slider value must not discard an explicit mask request that is
        // still queued for the same image. A newly opened image has its own bitmap.
        let pendingDetection = pendingPreviewRender.map {
            $0.request.shouldDetectSubjectMask && isCurrentPhotoImage($0.request.image) && isCurrentPhotoImage(request.image)
        } ?? false
        let request = PhotoStyleRenderRequest(
            style: request.style, adjustment: request.adjustment, image: request.image,
            subjectMask: request.subjectMask,
            shouldDetectSubjectMask: request.shouldDetectSubjectMask || pendingDetection
        )
        previewRevision &+= 1
        let cacheKey = previewCacheKey(for: request)
        if let cacheKey, let cached = photoPreviewCache.object(forKey: cacheKey as NSString),
           cached.mask === request.subjectMask,
           !request.shouldDetectSubjectMask || cached.mask != nil {
            pendingPreviewRender = nil
            outputImage = cached.output
            previewImagePayload = cached.payload
            sourceSubjectMask = cached.mask
            if !previewRenderRunning { finishPreviewWaiters() }
            updateActionAvailability()
            return
        }
        pendingPreviewRender = PhotoStylePreviewJob(revision: previewRevision, request: request, cacheKey: cacheKey,
                                                  maskDetectionImage: previewImage ?? request.image)
        startNextPreviewRender()
        updateActionAvailability()
    }

    func clearPreviewRender() {
        cancelAdjustmentPreview()
        previewRevision &+= 1
        pendingPreviewRender = nil
        outputImage = nil
        previewImagePayload = [:]
        loadingPreviewImagePayload = nil
        if !previewRenderRunning { finishPreviewWaiters() }
    }

    private func startNextPreviewRender() {
        guard !previewRenderRunning, let job = pendingPreviewRender else { return }
        pendingPreviewRender = nil
        previewRenderRunning = true
        let renderer = renderer
        let needsLoadingPreview = outputImage == nil && loadingPreviewImagePayload == nil
        previewRenderQueue.async { [weak self] in
            if needsLoadingPreview, let placeholder = imageDataURL(job.maskDetectionImage) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isLoadingImage, job.revision == self.previewRevision else { return }
                    self.loadingPreviewImagePayload = placeholder
                    self.sendState(includeImages: true)
                }
            }
            let (output, images, subjectMask) = autoreleasepool {
                let subjectMask = job.request.subjectMask ?? (job.request.shouldDetectSubjectMask
                    ? renderer.detectSubjectMask(for: job.maskDetectionImage) : nil)
                let output = renderer.render(.init(
                    style: job.request.style, adjustment: job.request.adjustment,
                    image: job.request.image, subjectMask: subjectMask, shouldDetectSubjectMask: false
                )).resizedForWebPreview(maxPixel: Self.processingPreviewMaxPixel)
                var images: [String: String] = [:]
                images["cropSourceImage"] = imageDataURL(job.request.image, maxPixel: PhotoImage.previewMaxPixel)
                let comparisonImage = croppedImage(job.request.image, adjustment: job.request.adjustment)
                images["sourceImage"] = imageDataURL(comparisonImage, maxPixel: Self.processingPreviewMaxPixel)
                images["outputImage"] = imageDataURL(output, maxPixel: Self.processingPreviewMaxPixel)
                return (output, images, subjectMask)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.previewRenderRunning = false
                if let cacheKey = job.cacheKey, images["outputImage"] != nil {
                    let cached = PhotoEditPreview(output: output, payload: images, mask: subjectMask)
                    self.photoPreviewCache.setObject(cached, forKey: cacheKey as NSString, cost: cached.cost)
                }
                if job.request.shouldDetectSubjectMask,
                   self.isCurrentPhotoImage(job.request.image) {
                    self.sourceSubjectMask = subjectMask
                    if let pending = self.pendingPreviewRender,
                       self.isCurrentPhotoImage(pending.request.image) {
                        self.pendingPreviewRender = PhotoStylePreviewJob(
                            revision: pending.revision,
                            request: .init(style: pending.request.style, adjustment: pending.request.adjustment,
                                           image: pending.request.image, subjectMask: subjectMask,
                                           shouldDetectSubjectMask: false),
                            cacheKey: pending.cacheKey,
                            maskDetectionImage: pending.maskDetectionImage
                        )
                    }
                }
                if job.revision == self.previewRevision {
                    self.outputImage = output
                    self.previewImagePayload = images
                    self.persistCurrentPhotoEdits()
                }
                if self.pendingPreviewRender != nil {
                    self.startNextPreviewRender()
                } else {
                    self.sendState(includeImages: true)
                    self.finishPreviewWaiters()
                }
            }
        }
    }

    @MainActor
    func waitForPreviewRender() async {
        guard isRenderingPreview else { return }
        await withCheckedContinuation { previewRenderWaiters.append($0) }
    }

    @MainActor
    func waitForPreviewRenderCancellable() async throws {
        try Task.checkCancellation()
        guard isRenderingPreview else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                cancellablePreviewWaiters[id] = continuation
            }
            try Task.checkCancellation()
        } onCancel: {
            DispatchQueue.main.async { [weak self] in
                self?.cancellablePreviewWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func finishPreviewWaiters() {
        guard !isRenderingPreview else { return }
        let waiters = previewRenderWaiters
        previewRenderWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let cancellable = cancellablePreviewWaiters.values
        cancellablePreviewWaiters.removeAll()
        cancellable.forEach { $0.resume() }
    }
}
