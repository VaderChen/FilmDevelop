import AppKit

/// A read-only preview lane: never writes selection, adjustments, history, or export pixels.
final class PhotoStyleFilmHoverPreview {
    private struct Job {
        let id: String
        let look: String
        let photo: UUID
        let revision: UInt64
        let selectedStyle: PhotoStyle
        let selectedCustomID: String?
        let request: PhotoStyleRenderRequest
    }
    private struct Cached {
        let job: Job
        let image: String
        let size: CGSize
    }
    private weak var coordinator: PhotoStyleWebCoordinator?
    private var currentID: String?
    private var pending: Job?
    private var running = false
    private var cache: [Cached] = []

    init(coordinator: PhotoStyleWebCoordinator) { self.coordinator = coordinator }

    func begin(_ payload: [String: Any]) {
        guard let coordinator, isAvailable(coordinator), let image = coordinator.previewImage,
              payload["photoGeneration"] as? String == coordinator.photoGeneration.uuidString,
              (payload["previewRevision"] as? NSNumber)?.uint64Value == coordinator.previewRevision,
              let id = payload["requestID"] as? String, !id.isEmpty, id.count <= 80,
              let look = payload["style"] as? String,
              look != (coordinator.selectedCustomFilmID ?? coordinator.selectedStyle.rawValue) else { return }
        let style: PhotoStyle
        var adjustment: StyleAdjustment
        if let film = coordinator.customFilmStore.film(id: look), let base = PhotoStyle(rawValue: film.baseStyle) {
            style = base
            adjustment = film.adjustment
        } else if let builtin = PhotoStyle(rawValue: look), builtin == .original || builtin.filmStock != nil {
            style = builtin
            adjustment = coordinator.adjustmentForSelectingStyle(builtin)
        } else { return }
        _ = adjustment.resolveHDRToneCurveFromAIAnalysisIfNeeded()
        let request = PhotoStyleRenderRequest(style: style, adjustment: coordinator.renderingAdjustment(adjustment),
            image: image, subjectMask: coordinator.sourceSubjectMask, shouldDetectSubjectMask: false)
        let job = Job(id: id, look: look, photo: coordinator.photoGeneration, revision: coordinator.previewRevision,
                      selectedStyle: coordinator.selectedStyle, selectedCustomID: coordinator.selectedCustomFilmID, request: request)
        currentID = id
        if let cached = cache.first(where: {
            $0.job.photo == job.photo && $0.job.revision == job.revision && $0.job.request.style == style
                && $0.job.request.adjustment == request.adjustment && $0.job.request.subjectMask === request.subjectMask
                && $0.job.request.image.cgImage === image.cgImage
        }) {
            pending = nil
            deliver(job, image: cached.image, size: cached.size)
            return
        }
        // At most one render is running and one newest hover is waiting.
        pending = job
        startNext()
    }

    func cancel(requestID: String? = nil, clearCache: Bool = false) {
        guard requestID == nil || requestID == currentID else { return }
        currentID = nil
        pending = nil
        if clearCache { cache.removeAll() }
    }

    private func isAvailable(_ coordinator: PhotoStyleWebCoordinator) -> Bool {
        !coordinator.isTerminating && !coordinator.isLoadingImage && !coordinator.isComputing
            && !coordinator.isSavingImage && !coordinator.isMCPMutating && !coordinator.isRenderingPreview
            && !coordinator.isDetectingSubjectMask && coordinator.sourceImage != nil
    }

    private func isCurrent(_ job: Job) -> Bool {
        guard let coordinator else { return false }
        return isAvailable(coordinator) && coordinator.photoGeneration == job.photo
            && coordinator.previewRevision == job.revision && coordinator.selectedStyle == job.selectedStyle
            && coordinator.selectedCustomFilmID == job.selectedCustomID
    }

    private func startNext() {
        guard !running, let job = pending, let coordinator else { return }
        pending = nil
        guard isCurrent(job) else { return }
        running = true
        let renderer = coordinator.renderer
        // Share the preview worker so hovering never starts several GPU renders at once.
        coordinator.previewRenderQueue.async { [weak self] in
            let result: (String?, CGSize) = autoreleasepool {
                let output = renderer.render(job.request)
                return (imageDataURL(output, maxPixel: PhotoImage.previewMaxPixel), output.size)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                if self.isCurrent(job), let image = result.0 {
                    self.cache.insert(Cached(job: job, image: image, size: result.1), at: 0)
                    if self.cache.count > 8 { self.cache.removeLast(self.cache.count - 8) }
                    self.deliver(job, image: image, size: result.1)
                }
                self.startNext()
            }
        }
    }

    private func deliver(_ job: Job, image: String, size: CGSize) {
        guard currentID == job.id, isCurrent(job) else { return }
        coordinator?.callJavaScript(function: "handleFilmHoverPreview", payload: [
            "requestID": job.id, "style": job.look, "photoGeneration": job.photo.uuidString,
            "previewRevision": job.revision, "image": image, "width": size.width, "height": size.height
        ])
    }
}
