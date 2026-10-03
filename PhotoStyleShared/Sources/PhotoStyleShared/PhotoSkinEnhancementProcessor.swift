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
            output = PhotoSkinRetouchProcessor.smooth(output, mask: skinMask, radius: max(1, radius), amount: smoothing)
        }

        if whitening > 0.005 {
            output = PhotoSkinRetouchProcessor.whiten(output, mask: skinMask, amount: whitening)
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
