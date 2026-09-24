import CoreImage
import CoreImage.CIFilterBuiltins

public enum PhotoBackgroundBlurProcessor {
    private static let backgroundKernel = CIColorKernel(source: """
    kernel vec4 isolatedBackground(__sample source, __sample mask) {
        float weight = clamp(1.0 - mask.r, 0.0, 1.0);
        return vec4(source.rgb * weight, 1.0);
    }
    """)

    private static let normalizeKernel = CIColorKernel(source: """
    kernel vec4 normalizedBackground(__sample blurred, __sample coverage, __sample source) {
        // 散景捲積在接近全遮罩處可能有微小負值，不能除以接近零的權重。
        vec3 color = max(blurred.rgb, vec3(0.0)) / max(coverage.r, 0.05);
        float confidence = smoothstep(0.05, 0.20, coverage.r);
        return mix(source, vec4(color, source.a), confidence);
    }
    """)

    public static func apply(
        to image: CIImage,
        personMask: CIImage,
        amount: Double,
        faceCenter: CGPoint? = nil,
        depthMask: CIImage? = nil
    ) -> CIImage {
        guard amount.isFinite else { return image }
        let amount = min(max(amount, 0), 1)
        guard amount > 0.005, isUsableExtent(image.extent) else { return image }

        let extent = image.extent
        let radius = blurRadius(for: extent, amount: amount)
        let softenedMask = refinedSubjectMask(personMask, extent: extent, blurRadius: radius)
        let backgroundMask = softenedMask.applyingFilter("CIColorInvert")
        guard let isolated = backgroundKernel?.apply(extent: extent, arguments: [image, softenedMask]) else {
            return image
        }
        // 排除主體後才產生散景，再按有效背景權重正規化，避免人物顏色滲入背景。
        func background(at radius: Double) -> CIImage {
            let color = bokeh(isolated, radius: radius)
            let coverage = bokeh(backgroundMask, radius: radius)
            return normalizeKernel?.apply(extent: extent, arguments: [color, coverage, image]) ?? image
        }
        let nearBlur = background(at: radius * 0.20)
        let farBlur = background(at: radius)
        let depth = (depthMask ?? backgroundDepthMask(extent: extent, faceCenter: faceCenter)).cropped(to: extent)
        let depthBlur = farBlur.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: nearBlur,
            kCIInputMaskImageKey: depth
        ])
        // 深度圖的焦平面須保持清晰，不能連零模糊區也套上最小半徑。
        let focusedBackground: CIImage
        if depthMask != nil {
            let focusTransition = depth.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 5, w: 0)
            ]).applyingFilter("CIColorClamp")
            focusedBackground = depthBlur.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: focusTransition
            ])
        } else {
            focusedBackground = depthBlur
        }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: focusedBackground,
            kCIInputMaskImageKey: softenedMask
        ]).cropped(to: extent)
    }

    private static func bokeh(_ image: CIImage, radius: Double) -> CIImage {
        image.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
            kCIInputRadiusKey: min(radius, 500),
            "inputRingAmount": 0,
            "inputSoftness": 0.3
        ]).cropped(to: image.extent)
    }

    public static func blurRadius(for extent: CGRect, amount: Double) -> Double {
        guard amount.isFinite, isUsableExtent(extent) else { return 0 }
        let amount = min(max(amount, 0), 1)
        let scale = resolutionScale(for: extent)
        return min(500, amount * 24 * scale)
    }

    public static func refinedSubjectMask(
        _ subjectMask: CIImage,
        extent: CGRect,
        blurRadius: Double
    ) -> CIImage {
        guard isUsableExtent(extent) else { return CIImage.empty() }
        let scale = resolutionScale(for: extent)
        let expansionRadius = max(1 * scale, blurRadius * 0.14)
        let featherRadius = max(1.2 * scale, blurRadius * 0.08)
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
        max(extent.width, extent.height) / 1024
    }

    private static func isUsableExtent(_ extent: CGRect) -> Bool {
        !extent.isInfinite && !extent.isEmpty
            && extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
    }
}
