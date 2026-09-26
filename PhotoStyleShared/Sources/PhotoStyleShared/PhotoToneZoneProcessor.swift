import CoreImage

public struct PhotoToneZoneGrainAmounts: Equatable, Sendable {
    public let highlights: Double
    public let midtones: Double
    public let shadows: Double

    public init(highlights: Double, midtones: Double, shadows: Double) {
        self.highlights = highlights
        self.midtones = midtones
        self.shadows = shadows
    }
}

public struct PhotoToneZoneMappingAmounts: Equatable, Sendable {
    public let shadows: Double
    public let midtones: Double
    public let highlights: Double

    public init(shadows: Double, midtones: Double, highlights: Double) {
        self.shadows = min(max(shadows, 0), 1)
        self.midtones = min(max(midtones, 0), 1)
        self.highlights = min(max(highlights, 0), 1)
    }

    public static let full = PhotoToneZoneMappingAmounts(
        shadows: 1,
        midtones: 1,
        highlights: 1
    )
}

public enum PhotoToneZoneProcessor {
    private static let compositeKernel = CIColorKernel(source: """
    kernel vec4 compositeToneZones(
        __sample base,
        __sample shadows,
        __sample midtones,
        __sample highlights,
        __sample shadowMask,
        __sample midtoneMask,
        __sample highlightMask,
        float shadowAmount,
        float midtoneAmount,
        float highlightAmount
    ) {
        float shadowWeight = clamp(shadowMask.r, 0.0, 1.0);
        float midtoneWeight = clamp(midtoneMask.r, 0.0, 1.0);
        float highlightWeight = clamp(highlightMask.r, 0.0, 1.0);
        float totalWeight = shadowWeight + midtoneWeight + highlightWeight;
        if (totalWeight <= 0.0001) {
            return base;
        }
        vec3 shadowColor = mix(base.rgb, shadows.rgb, clamp(shadowAmount, 0.0, 1.0));
        vec3 midtoneColor = mix(base.rgb, midtones.rgb, clamp(midtoneAmount, 0.0, 1.0));
        vec3 highlightColor = mix(base.rgb, highlights.rgb, clamp(highlightAmount, 0.0, 1.0));
        vec3 color = (
            shadowColor * shadowWeight
            + midtoneColor * midtoneWeight
            + highlightColor * highlightWeight
        ) / totalWeight;
        return vec4(color, base.a);
    }
    """)

    public static func blend(_ adjusted: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: background.extent)
    }

    public static func composite(
        base: CIImage,
        shadows: CIImage,
        midtones: CIImage,
        highlights: CIImage,
        masks: PhotoToneMasks,
        mappingAmounts: PhotoToneZoneMappingAmounts = .full
    ) -> CIImage {
        // Identical branches contribute no change; skip masks and native readback.
        guard !(shadows === base && midtones === base && highlights === base) else { return base }
        guard let compositeKernel,
              let output = compositeKernel.apply(
                extent: base.extent,
                arguments: [
                    base,
                    shadows,
                    midtones,
                    highlights,
                    masks.shadows,
                    masks.midtones,
                    masks.highlights,
                    Float(mappingAmounts.shadows),
                    Float(mappingAmounts.midtones),
                    Float(mappingAmounts.highlights)
                ]
              ) else {
            return base
        }
        return output.cropped(to: base.extent)
    }

    public static func applyDenoise(
        to image: CIImage,
        masks: PhotoToneMasks,
        amount: Double,
        strength: Double
    ) -> CIImage {
        guard amount > 0.005 else { return image }
        return composite(
            base: image,
            shadows: denoised(image, amount: amount * strength),
            midtones: denoised(image, amount: amount * strength * 0.55),
            highlights: denoised(image, amount: amount * strength * 0.25),
            masks: masks
        )
    }

    public static func applyGrain(
        to image: CIImage,
        masks: PhotoToneMasks,
        highlightAmount: Double,
        midtoneAmount: Double,
        shadowAmount: Double,
        profile: PhotoGrainProfile,
        filmEffects: PhotoFilmEffects = .neutral,
        monochrome: Bool = false
    ) -> CIImage {
        PhotoEmulsionExposureProcessor.apply(to: image, effects: filmEffects,
            amounts: .init(highlights: highlightAmount, midtones: midtoneAmount, shadows: shadowAmount),
            monochrome: monochrome)
    }

    public static func resolvedGrainAmounts(
        globalAmount: Double,
        highlightAmount: Double,
        midtoneAmount: Double,
        shadowAmount: Double
    ) -> PhotoToneZoneGrainAmounts {
        let globalAmount = clamped(globalAmount)
        return .init(
            highlights: max(clamped(highlightAmount), globalAmount * 0.45),
            midtones: max(clamped(midtoneAmount), globalAmount * 0.75),
            shadows: max(clamped(shadowAmount), globalAmount)
        )
    }

    private static func denoised(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0.005 else { return image }
        return PhotoNoiseProcessor.denoise(image, amount: amount)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
