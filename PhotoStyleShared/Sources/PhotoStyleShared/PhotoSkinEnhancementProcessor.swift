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
        profile: PhotoSkinEnhancementProfile
    ) -> CIImage {
        let whitening = clamped(whitening)
        let smoothing = clamped(smoothing)
        guard whitening > 0.005 || smoothing > 0.005 else { return image }

        var output = image
        if smoothing > 0.005 {
            let radius = (0.9 + smoothing * 5.4) * radiusScale(for: image.extent, profile: profile)
            let smoothed = output
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: image.extent)
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
                    value: min(0.68, whitening * 0.76)
                )
            ])
        }

        return output
    }

    private static func radiusScale(for extent: CGRect, profile: PhotoSkinEnhancementProfile) -> Double {
        switch profile {
        case .app:
            return max(min(extent.width, extent.height) / 1600, 0.5)
        case .plan:
            return min(max(max(extent.width, extent.height) / 1024, 0.5), 3)
        }
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
