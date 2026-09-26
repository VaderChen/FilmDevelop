import CoreImage

public struct PhotoPlanToneComponents: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let baseTone = PhotoPlanToneComponents(rawValue: 1 << 0)
    public static let exposure = PhotoPlanToneComponents(rawValue: 1 << 1)
    public static let contrast = PhotoPlanToneComponents(rawValue: 1 << 2)
    public static let warmth = PhotoPlanToneComponents(rawValue: 1 << 3)
    public static let tint = PhotoPlanToneComponents(rawValue: 1 << 4)
    public static let highlightShadow = PhotoPlanToneComponents(rawValue: 1 << 5)
    public static let fade = PhotoPlanToneComponents(rawValue: 1 << 6)
    public static let softness = PhotoPlanToneComponents(rawValue: 1 << 7)
    public static let mapping = PhotoPlanToneComponents(rawValue: 1 << 8)

    public static let appSupplement: PhotoPlanToneComponents = [
        .baseTone,
        .contrast,
        .tint,
        .highlightShadow,
        .fade,
        .softness
    ]

    public static let appAutoSupplement: PhotoPlanToneComponents = [
        .baseTone,
        .contrast,
        .tint,
        .highlightShadow,
        .fade,
        .softness
    ]

    public static let appMonochromeSupplement: PhotoPlanToneComponents = [
        .contrast,
        .highlightShadow,
        .fade,
        .softness
    ]

    public static let all: PhotoPlanToneComponents = [
        .baseTone,
        .exposure,
        .contrast,
        .warmth,
        .tint,
        .highlightShadow,
        .fade,
        .softness,
        .mapping
    ]
}

public enum PhotoPlanToneProcessor {
    public static func apply(
        to image: CIImage,
        toneZones: PhotoStylePlan.ToneZones,
        masks: PhotoToneMasks,
        strength: Double,
        components: PhotoPlanToneComponents = .all
    ) -> CIImage {
        let strength = min(max(strength, 0), 1)
        guard strength > 0.001, !components.isEmpty else { return image }

        let shadowAdjusted = applyZone(
            to: image,
            adjustment: toneZones.shadows,
            strength: strength,
            components: components
        )
        let midtoneAdjusted = toneZones.midtones == toneZones.shadows ? shadowAdjusted : applyZone(
            to: image,
            adjustment: toneZones.midtones,
            strength: strength,
            components: components
        )
        let highlightAdjusted = toneZones.highlights == toneZones.shadows ? shadowAdjusted
            : toneZones.highlights == toneZones.midtones ? midtoneAdjusted : applyZone(
            to: image,
            adjustment: toneZones.highlights,
            strength: strength,
            components: components
        )
        let mappingAmounts = components.contains(.mapping)
            ? PhotoToneZoneMappingAmounts(
                shadows: normalized(toneZones.shadows.mapping),
                midtones: normalized(toneZones.midtones.mapping),
                highlights: normalized(toneZones.highlights.mapping)
            )
            : .full
        return PhotoToneZoneProcessor.composite(
            base: image,
            shadows: shadowAdjusted,
            midtones: midtoneAdjusted,
            highlights: highlightAdjusted,
            masks: masks,
            mappingAmounts: mappingAmounts
        )
    }

    private static func applyZone(
        to image: CIImage,
        adjustment: PhotoStylePlan.ToneAdjustment,
        strength: Double,
        components: PhotoPlanToneComponents
    ) -> CIImage {
        var adjusted = image

        if components.contains(.exposure) {
            let exposureEV = PhotoExposureScale.ev(fromSlider: Double(adjustment.exposure)) * strength
            adjusted = PhotoToneProcessor.applyExposure(to: adjusted, ev: exposureEV)
        }

        let saturation = components.contains(.baseTone)
            ? 1 + signedNormalized(adjustment.baseTone) * 0.55 * strength
            : 1
        let contrast = components.contains(.contrast)
            ? signedNormalized(adjustment.contrast) * strength
            : 0
        if abs(saturation - 1) > 0.001 {
            adjusted = PhotoImageEffectsProcessor.colorControls(
                adjusted,
                saturation: saturation
            )
        }

        let warmth = components.contains(.warmth)
            ? signedNormalized(adjustment.warmth) * strength
            : 0
        let tint = components.contains(.tint)
            ? signedNormalized(adjustment.tint) * strength
            : 0
        adjusted = PhotoToneProcessor.applyTemperatureAndTint(
            to: adjusted,
            warmth: warmth,
            tint: tint,
            profile: .plan
        )

        let highlights = components.contains(.highlightShadow)
            ? signedNormalized(adjustment.highlights) * strength
            : 0
        let shadows = components.contains(.highlightShadow)
            ? signedNormalized(adjustment.shadows) * strength
            : 0
        adjusted = PhotoLocalToneProcessor.apply(
            to: adjusted,
            contrast: contrast,
            highlights: highlights,
            shadows: shadows
        )
        if components.contains(.fade) {
            adjusted = PhotoImageEffectsProcessor.fade(
                adjusted,
                amount: normalized(adjustment.fade) * strength
            )
        }
        if components.contains(.softness) {
            adjusted = PhotoImageEffectsProcessor.soften(
                adjusted,
                amount: normalized(adjustment.softness) * strength
            )
        }

        return adjusted
    }

    private static func normalized(_ value: Int) -> Double {
        Double(min(max(value, 0), 100)) / 100
    }

    private static func signedNormalized(_ value: Int) -> Double {
        Double(min(max(value, -100), 100)) / 100
    }
}
