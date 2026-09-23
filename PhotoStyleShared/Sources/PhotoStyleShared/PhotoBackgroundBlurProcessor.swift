import CoreImage
import CoreImage.CIFilterBuiltins

public enum PhotoBackgroundBlurProcessor {
    public static func apply(
        to image: CIImage,
        personMask: CIImage,
        amount: Double,
        faceCenter: CGPoint? = nil
    ) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.005, isUsableExtent(image.extent) else { return image }

        let extent = image.extent
        let scale = resolutionScale(for: extent)
        let radius = blurRadius(for: extent, amount: amount)
        let lowRadius = max(0.5 * scale, radius * 0.18)
        let lowBlur = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: lowRadius])
            .cropped(to: extent)
        let highBlur = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        let depthBlur = highBlur.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: lowBlur,
            kCIInputMaskImageKey: backgroundDepthMask(extent: extent, faceCenter: faceCenter)
        ])
        let softenedMask = refinedSubjectMask(
            personMask,
            extent: extent,
            blurRadius: radius
        )
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: depthBlur,
            kCIInputMaskImageKey: softenedMask
        ]).cropped(to: extent)
    }

    public static func blurRadius(for extent: CGRect, amount: Double) -> Double {
        guard isUsableExtent(extent) else { return 0 }
        let amount = min(max(amount, 0), 1)
        let scale = resolutionScale(for: extent)
        return max(0.75 * scale, amount * 18 * scale)
    }

    public static func refinedSubjectMask(
        _ subjectMask: CIImage,
        extent: CGRect,
        blurRadius: Double
    ) -> CIImage {
        guard isUsableExtent(extent) else { return CIImage.empty() }
        let scale = resolutionScale(for: extent)
        let expansionRadius = min(12 * scale, max(1 * scale, blurRadius * 0.14))
        let featherRadius = min(8 * scale, max(1.2 * scale, blurRadius * 0.08))
        let normalized = subjectMask
            .cropped(to: extent)
            .clampedToExtent()
        let expanded = normalized
            .applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: expansionRadius
            ])
            .cropped(to: extent)
        return expanded
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: featherRadius
            ])
            .cropped(to: extent)
    }

    static func backgroundDepthMask(extent: CGRect, faceCenter: CGPoint?) -> CIImage {
        guard isUsableExtent(extent) else { return CIImage.empty() }
        let fallbackFaceY = extent.minY + extent.height * 0.62
        let requestedFaceY = faceCenter?.y ?? fallbackFaceY
        let faceY = min(max(requestedFaceY.isFinite ? requestedFaceY : fallbackFaceY, extent.minY + 1), extent.maxY)
        let distance = max(faceY - extent.minY, 1)
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: extent.minY + distance * 0.08)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.minY + distance)
        gradient.color0 = .black
        gradient.color1 = .white
        return gradient.outputImage?.cropped(to: extent) ?? CIImage(color: .white).cropped(to: extent)
    }

    private static func resolutionScale(for extent: CGRect) -> Double {
        min(max(max(extent.width, extent.height) / 1024, 0.5), 3)
    }

    private static func isUsableExtent(_ extent: CGRect) -> Bool {
        !extent.isInfinite && !extent.isEmpty
            && extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
    }
}
