import CoreImage

public enum PhotoGrainProfile: Sendable {
    case overlay
    case softLight
}

public enum PhotoNoiseProcessor {
    public static func denoise(_ image: CIImage, amount: Double) -> CIImage {
        let amount = clamped(amount)
        guard amount > 0.005 else { return image }

        return image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": min(0.08, amount * 0.08),
            "inputSharpness": max(0.35, 0.85 - amount * 0.35)
        ])
    }

    public static func addGrain(
        to image: CIImage,
        amount: Double,
        profile: PhotoGrainProfile,
        seed: UInt32 = 0
    ) -> CIImage {
        PhotoEmulsionExposureProcessor.apply(to: image, effects: .neutral,
            amounts: .init(highlights: amount, midtones: amount, shadows: amount), seed: seed)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
