import CoreImage

public enum PhotoMonochromeProfile: Sendable {
    case noir
    case desaturate
}

public enum PhotoImageEffectsProcessor {
    public static func colorControls(
        _ image: CIImage,
        saturation: Double = 1,
        brightness: Double = 0,
        contrast: Double = 1
    ) -> CIImage {
        // Exact identity: avoid a graph node, GPU pass and native-stage readback.
        guard saturation != 1 || brightness != 0 || contrast != 1 else { return image }
        return image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast
        ])
    }

    public static func monochrome(_ image: CIImage, profile: PhotoMonochromeProfile) -> CIImage {
        switch profile {
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .desaturate:
            return colorControls(image, saturation: 0)
        }
    }

    public static func blend(_ filtered: CIImage, with original: CIImage, opacity: Double) -> CIImage {
        let opacity = min(max(opacity, 0), 1)
        if opacity <= 0 { return original }
        if opacity >= 1 { return filtered }
        let foreground = filtered.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
        ])
        return foreground.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: original
        ])
    }

    public static func fade(_ image: CIImage, amount: Double) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.005 else { return image }
        let lift = min(0.18, amount * 0.18)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 - lift * 0.25, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 - lift * 0.20, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 - lift * 0.18, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
        ])
    }

    public static func soften(_ image: CIImage, amount: Double) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.005 else { return image }
        let scale = min(max(max(image.extent.width, image.extent.height) / 1024, 0.5), 3)
        let radius = (0.75 + amount * 7) * scale
        let opacity = min(0.66, amount * 1.18)
        let softened = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        return blend(softened, with: image, opacity: opacity)
    }
}
