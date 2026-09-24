import CoreImage

public enum PhotoSkinEnhancementProfile: Sendable {
    case app
    case plan
}

public enum PhotoSkinEnhancementProcessor {
    public static func apply(
        to image: CIImage,
        skinMask: CIImage,
        whitening: Double,
        smoothing: Double,
        profile: PhotoSkinEnhancementProfile,
        warmth: Double = 0
    ) -> CIImage {
        let whitening = clamped(whitening)
        let smoothing = clamped(smoothing)
        let warmth = warmth.isFinite ? min(1, max(-1, warmth)) : 0
        guard whitening > 0.005 || smoothing > 0.005 || abs(warmth) > 0.001 else { return image }

        var output = image
        if smoothing > 0.005 {
            let radius = (0.9 + smoothing * 5.4) * radiusScale(for: image.extent, profile: profile)
            // 以原圖引導平滑，抑制細小膚質紋理，同時保留五官與輪廓邊緣。
            let smoothed = guidedSmooth(output, radius: max(1, radius), epsilon: 0.002 + smoothing * 0.018)
            output = smoothed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: PhotoMaskProcessor.opacity(
                    skinMask,
                    value: min(0.58, smoothing * 0.65)
                )
            ])
        }

        if whitening > 0.005 {
            let whitened = output.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0 - whitening * 0.16,
                kCIInputBrightnessKey: whitening * 0.13,
                kCIInputContrastKey: 1.0 - whitening * 0.07
            ])
            output = whitened.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: PhotoMaskProcessor.opacity(
                    skinMask,
                    // 色調變化已包含 whitening，不再把強度乘第二次。
                    value: 0.68
                )
            ])
        }

        if abs(warmth) > 0.001 {
            let tinted = PhotoToneProcessor.applyTemperatureAndTint(to: output, warmth: warmth * 100, tint: 0, profile: .app)
            output = tinted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: skinMask
            ])
        }
        return output
    }

    // 自引導濾波：每個色彩通道計算 a=var/(var+ε)、b=mean*(1-a)，
    // 再平均 a、b 並重建。不同於高斯模糊，強邊緣的 a 接近 1。
    // 係數只處理非預乘 RGB；輸出沿用來源 alpha，保留浮點高光。
    private static func guidedSmooth(_ image: CIImage, radius: Double, epsilon: Double) -> CIImage {
        let extent = image.extent
        guard let prepared = unpremultiply?.apply(extent: extent, arguments: [image]),
              let squared = square?.apply(extent: extent, arguments: [prepared]) else { return image }
        func mean(_ value: CIImage) -> CIImage {
            PhotoBoxMeanFilter.apply(value, radius: radius)
        }
        let average = mean(prepared)
        guard let slope = coefficientA?.apply(extent: extent, arguments: [average, mean(squared), epsilon]),
              let intercept = coefficientB?.apply(extent: extent, arguments: [average, slope]),
              let result = reconstruction?.apply(extent: extent, arguments: [image, mean(slope), mean(intercept)]) else { return image }
        return result
    }

    private static let unpremultiply = CIColorKernel(source: """
    kernel vec4 skinGuideInput(__sample image) {
        return vec4(image.rgb / max(image.a, 0.0000001), 1.0);
    }
    """)
    private static let square = CIColorKernel(source: """
    kernel vec4 skinGuideSquare(__sample image) { return vec4(image.rgb * image.rgb, 1.0); }
    """)
    private static let coefficientA = CIColorKernel(source: """
    kernel vec4 skinGuideA(__sample mean, __sample correlation, float epsilon) {
        vec3 variance = max(correlation.rgb - mean.rgb * mean.rgb, vec3(0.0));
        return vec4(variance / (variance + vec3(epsilon)), 1.0);
    }
    """)
    private static let coefficientB = CIColorKernel(source: """
    kernel vec4 skinGuideB(__sample mean, __sample slope) { return vec4(mean.rgb * (vec3(1.0) - slope.rgb), 1.0); }
    """)
    private static let reconstruction = CIColorKernel(source: """
    kernel vec4 skinGuideReconstruct(__sample image, __sample slope, __sample intercept) {
        return vec4(image.rgb * slope.rgb + intercept.rgb * image.a, image.a);
    }
    """)

    private static func radiusScale(for extent: CGRect, profile: PhotoSkinEnhancementProfile) -> Double {
        switch profile {
        case .app:
            return max(min(extent.width, extent.height) / 1600, 0.5)
        case .plan:
            return min(max(max(extent.width, extent.height) / 1024, 0.5), 3)
        }
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
