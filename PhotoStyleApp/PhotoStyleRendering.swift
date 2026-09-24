import CoreImage
import AppKit
import PhotoStyleShared

struct PhotoStyleRenderRequest {
    let style: PhotoStyle
    let adjustment: StyleAdjustment
    let image: PhotoImage
    let subjectMask: CIImage?
    let shouldDetectSubjectMask: Bool
    var repairPatches: [PhotoRepairPatch] = []
}

protocol PhotoStyleRendering: Sendable {
    var canDetectSubjectMask: Bool { get }

    func detectSubjectMask(for image: PhotoImage) -> CIImage?

    func render(_ request: PhotoStyleRenderRequest) -> PhotoImage
}

struct CoreImagePhotoStyleRenderer: PhotoStyleRendering {
    var canDetectSubjectMask: Bool {
        PhotoStyleProcessor.canDetectSubjectMask
    }

    func detectSubjectMask(for image: PhotoImage) -> CIImage? {
        PhotoStyleProcessor.detectSubjectMask(for: image)
    }

    func render(_ request: PhotoStyleRenderRequest) -> PhotoImage {
        PhotoStyleProcessor.apply(
            style: request.style,
            adjustment: request.adjustment,
            to: request.image,
            subjectMask: request.subjectMask,
            shouldDetectSubjectMask: request.shouldDetectSubjectMask,
            repairPatches: request.repairPatches
        )
    }
}
