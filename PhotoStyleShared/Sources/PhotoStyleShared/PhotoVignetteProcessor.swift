import CoreImage
import CoreImage.CIFilterBuiltins

public enum PhotoVignetteProfile: Sendable {
    case app
    case plan
}

public enum PhotoMaskProcessor {
    public static func opacity(_ mask: CIImage, value: Double) -> CIImage {
        let value = value.isNaN ? 0 : min(max(value, 0), 1)
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }
}

public enum PhotoVignetteProcessor {
    public static func applyVignette(
        to image: CIImage,
        amount: Double,
        profile: PhotoVignetteProfile
    ) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.005, isUsableExtent(image.extent) else { return image }

        let intensity: Double
        let radius: Double
        switch profile {
        case .app:
            intensity = amount * 0.9
            radius = 1.8
        case .plan:
            intensity = min(1.0, amount * 1.1)
            radius = 1.65
        }
        return image.applyingFilter("CIVignette", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: intensity
        ])
    }

    public static func applyDevignette(
        to image: CIImage,
        amount: Double,
        profile: PhotoVignetteProfile
    ) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.005, isUsableExtent(image.extent) else { return image }

        let lifted = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: min(0.12, amount * 0.12),
            kCIInputContrastKey: max(0.88, 1.0 - amount * 0.06)
        ])
        let mask = PhotoMaskProcessor.opacity(
            cornerMask(extent: image.extent, profile: profile),
            value: min(0.72, amount * 0.72)
        )
        return lifted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ])
    }

    public static func cornerMask(extent: CGRect, profile: PhotoVignetteProfile) -> CIImage {
        guard isUsableExtent(extent) else { return CIImage.empty() }
        switch profile {
        case .app:
            let filter = CIFilter.radialGradient()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius0 = Float(min(extent.width, extent.height) * 0.32)
            filter.radius1 = Float(max(extent.width, extent.height) * 0.78)
            filter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            return filter.outputImage?.cropped(to: extent) ?? blackMask(extent: extent)

        case .plan:
            let radius = max(max(extent.width, extent.height) * 0.72, 1)
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: extent.midX, y: extent.midY)
            gradient.radius0 = Float(radius * 0.52)
            gradient.radius1 = Float(radius)
            gradient.color0 = .black
            gradient.color1 = .white
            // CIRadialGradient supplies clamped t; smoothstep(t) = 3t² − 2t³.
            let smooth = CIFilter.colorPolynomial()
            smooth.inputImage = gradient.outputImage
            let coefficients = CIVector(x: 0, y: 0, z: 3, w: -2)
            smooth.redCoefficients = coefficients
            smooth.greenCoefficients = coefficients
            smooth.blueCoefficients = coefficients
            return smooth.outputImage?.cropped(to: extent) ?? blackMask(extent: extent)
        }
    }

    private static func blackMask(extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
    }

    private static func isUsableExtent(_ extent: CGRect) -> Bool {
        !extent.isInfinite && !extent.isEmpty
            && extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
    }
}
