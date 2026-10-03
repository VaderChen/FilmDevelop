import CoreImage

public enum PhotoGrainProfile: Sendable {
    case overlay
    case softLight
}

public enum PhotoNoiseProcessor {
    public static func denoise(_ image: CIImage, amount: Double) -> CIImage {
        let amount = clamped(amount)
        guard amount > 0.005 else { return image }

        // 使用與 C++／Vulkan 相同的視窗與噪聲變異量，避免系統濾鏡的
        // 未公開強度曲線造成跨平台手感不同；不加銳化、不裁切 HDR。
        let noise = amount * 0.08
        return PhotoGuidedChannelFilter.apply(image, radius: 2, epsilon: noise * noise)
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
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
