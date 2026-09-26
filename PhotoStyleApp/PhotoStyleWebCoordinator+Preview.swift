import AppKit

struct PhotoStylePreviewJob {
    let revision: UInt64
    let request: PhotoStyleRenderRequest
    let cacheKey: String?
    let maskDetectionImage: PhotoImage
    let photoGeneration: UUID
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
            shouldDetectSubjectMask: request.shouldDetectSubjectMask || pendingDetection, repairPatches: request.repairPatches
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
                                                  maskDetectionImage: previewImage ?? request.image, photoGeneration: photoGeneration)
        startNextPreviewRender()
        updateActionAvailability()
    }

    func clearPreviewRender() {
        let sourceCache = previewSourcePayloadCache
        previewRenderQueue.async { sourceCache.begin(photoGeneration: UUID()) }
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
        let sourceCache = previewSourcePayloadCache
        let needsLoadingPreview = outputImage == nil && loadingPreviewImagePayload == nil
        previewRenderQueue.async { [weak self] in
            sourceCache.begin(photoGeneration: job.photoGeneration)
            if needsLoadingPreview, let placeholder = imageDataURL(job.maskDetectionImage) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isLoadingImage, job.revision == self.previewRevision else { return }
                    self.loadingPreviewImagePayload = placeholder
                    self.sendState(includeImages: true)
                }
            }
            let (output, images, subjectMask) = autoreleasepool {
                let subjectMask = job.request.subjectMask ?? (job.request.shouldDetectSubjectMask
                    ? renderer.detectSubjectMask(for: PhotoStyleProcessor.repairedSource(job.maskDetectionImage, patches: job.request.repairPatches)) : nil)
                let output = renderer.render(.init(
                    style: job.request.style, adjustment: job.request.adjustment,
                    image: job.request.image, subjectMask: subjectMask, shouldDetectSubjectMask: false, repairPatches: job.request.repairPatches, isPreview: true
                )).resizedForWebPreview(maxPixel: Self.processingPreviewMaxPixel)
                var images: [String: String] = [:]
                images["cropSourceImage"] = sourceCache.value(for: job.request.image, variant: "crop-source") {
                    imageDataURL(job.request.image, maxPixel: PhotoImage.previewMaxPixel)
                }
                let repairs = job.request.repairPatches.map { $0.id.uuidString }.joined(separator: ",")
                images["repairSourceImage"] = sourceCache.value(for: job.maskDetectionImage, variant: "repair:" + repairs) {
                    imageDataURL(PhotoStyleProcessor.repairedSource(job.maskDetectionImage, patches: job.request.repairPatches), maxPixel: PhotoImage.previewMaxPixel)
                }
                let a = job.request.adjustment
                let crop = "\(a.cropAspectRatio):\(a.cropRotation):\(a.cropScale):\(a.cropWidth):\(a.cropHeight):\(a.cropHorizontalPosition):\(a.cropVerticalPosition)"
                images["sourceImage"] = sourceCache.value(for: job.request.image, variant: "comparison:" + crop) {
                    imageDataURL(croppedImage(job.request.image, adjustment: a), maxPixel: Self.processingPreviewMaxPixel)
                }
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
                   job.photoGeneration == self.photoGeneration,
                   job.request.repairPatches.map(\.id) == self.repairPatches.map(\.id),
                   self.isCurrentPhotoImage(job.request.image) {
                    self.sourceSubjectMask = subjectMask
                    self.subjectMaskAttemptedGeneration = self.photoGeneration
                    if let pending = self.pendingPreviewRender,
                       pending.photoGeneration == job.photoGeneration,
                       pending.request.repairPatches.map(\.id) == job.request.repairPatches.map(\.id),
                       self.isCurrentPhotoImage(pending.request.image) {
                        self.pendingPreviewRender = PhotoStylePreviewJob(
                            revision: pending.revision,
                            request: .init(style: pending.request.style, adjustment: pending.request.adjustment,
                                           image: pending.request.image, subjectMask: subjectMask,
                                           shouldDetectSubjectMask: false, repairPatches: pending.request.repairPatches),
                            cacheKey: pending.cacheKey,
                            maskDetectionImage: pending.maskDetectionImage, photoGeneration: pending.photoGeneration
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

/// 僅由序列 previewRenderQueue 存取；保留影像身分，避免指標重用造成錯配。
/// 切換照片即清除，最多六筆／16 MiB 編碼資料，不保留歷史照片。
final class PhotoPreviewSourcePayloadCache {
    private struct Entry {
        let image: CGImage
        let variant: String
        let payload: String
    }
    private var generation: UUID?
    private var entries: [Entry] = []
    private(set) var encodingCount = 0

    func begin(photoGeneration: UUID) {
        guard generation != photoGeneration else { return }
        generation = photoGeneration
        entries.removeAll()
    }

    func value(for image: PhotoImage, variant: String, create: () -> String?) -> String? {
        guard let bitmap = image.cgImage else { return create() }
        if let index = entries.firstIndex(where: { $0.image === bitmap && $0.variant == variant }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.payload
        }
        encodingCount += 1
        guard let payload = create() else { return nil }
        entries.append(Entry(image: bitmap, variant: variant, payload: payload))
        while entries.count > 6 || entries.reduce(0, { $0 + $1.payload.utf8.count }) > 16 * 1024 * 1024 {
            entries.removeFirst()
        }
        return payload
    }
}
