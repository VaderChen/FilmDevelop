import PhotoStyleShared

enum PhotoStylePlanPolicyResolver {
    private struct Limits {
        let baseTone: ClosedRange<Int>
        let exposure: ClosedRange<Int>
        let contrast: ClosedRange<Int>
        let softness: ClosedRange<Int>
        let grain: ClosedRange<Int>
        let highlightShadow: ClosedRange<Int>
        let fade: ClosedRange<Int>
        let warmth: ClosedRange<Int>
        let tint: ClosedRange<Int>
        let mapping: ClosedRange<Int>

        // A style can limit the size of a correction, but must allow no correction.
        var includingNeutral: Limits {
            func includeZero(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
                min(range.lowerBound, 0)...max(range.upperBound, 0)
            }
            return Limits(
                baseTone: includeZero(baseTone), exposure: includeZero(exposure),
                contrast: includeZero(contrast), softness: includeZero(softness),
                grain: includeZero(grain), highlightShadow: includeZero(highlightShadow),
                fade: includeZero(fade), warmth: includeZero(warmth),
                tint: includeZero(tint), mapping: includeZero(mapping)
            )
        }
    }

    static func resolve(
        _ input: PhotoStylePlan,
        style: PhotoStyle,
        usesCustomPrompt: Bool = false
    ) -> PhotoStylePlan {
        var output = input
        let usesCustomPrompt = usesCustomPrompt || input.editorControls != nil
        let limits = usesCustomPrompt ? physicalLimits : limits(for: style).includingNeutral
        output.strength = input.strength <= 0
            ? 0
            : input.strength.clamped(to: usesCustomPrompt ? 0...100 : style.llmStrengthRange)
        output.colorMode = style.isMonochrome ? "monochrome" : "color"
        // Film controls carry explicit physical values; style presets must not
        // introduce glow or replace a requested zero with an aesthetic minimum.
        output.filmEffects = input.filmEffects.clamped()
        output.backgroundBlur = input.backgroundBlur.clamped(to: 0...100)
        output.skinWhitening = input.skinWhitening.clamped(to: 0...100)
        output.skinSmoothing = input.skinSmoothing.clamped(to: 0...100)
        output.hdrToneCurve = input.hdrToneCurve.map { clampHDRToneCurve($0, usesCustomPrompt: usesCustomPrompt) }
        output.postProcessing.grain = input.postProcessing.grain.clamped(to: 0...limits.grain.upperBound)
        output.postProcessing.denoise = input.postProcessing.denoise.clamped(to: 0...100)
        output.postProcessing.vignette = input.postProcessing.vignette.clamped(to: 0...100)
        output.postProcessing.devignette = input.postProcessing.devignette.clamped(to: 0...100)

        var toneZones = input.toneZones
        // Zero and small signed values are explicit instructions, not missing fields.
        toneZones.shadows = clamp(toneZones.shadows, to: limits, region: .shadows, style: style, usesCustomPrompt: usesCustomPrompt)
        toneZones.midtones = clamp(toneZones.midtones, to: limits, region: .midtones, style: style, usesCustomPrompt: usesCustomPrompt)
        toneZones.highlights = clamp(toneZones.highlights, to: limits, region: .highlights, style: style, usesCustomPrompt: usesCustomPrompt)
        output.toneZones = toneZones
        return output
    }

    private static func clampHDRToneCurve(
        _ curve: PhotoStylePlan.HDRToneCurve,
        usesCustomPrompt: Bool
    ) -> PhotoStylePlan.HDRToneCurve {
        if usesCustomPrompt {
            let black = curve.black.clamped(to: 0...100)
            let shadows = curve.shadows.clamped(to: black...100)
            let midtones = curve.midtones.clamped(to: shadows...100)
            let highlights = curve.highlights.clamped(to: midtones...100)
            return .init(
                black: black, shadows: shadows, midtones: midtones,
                highlights: highlights, white: curve.white.clamped(to: highlights...100),
                detail: curve.detail.clamped(to: 0...40)
            )
        }
        let black = curve.black.clamped(to: 0...15)
        let shadows = curve.shadows.clamped(to: max(black + 4, 16)...48)
        let midtones = curve.midtones.clamped(to: max(shadows + 4, 36)...68)
        let highlights = curve.highlights.clamped(to: max(midtones + 4, 56)...92)
        let white = curve.white.clamped(to: max(highlights + 4, 88)...100)
        return .init(
            black: black,
            shadows: shadows,
            midtones: midtones,
            highlights: highlights,
            white: white,
            detail: curve.detail.clamped(to: 0...40)
        )
    }

    private enum Region {
        case shadows
        case midtones
        case highlights
    }

    private static let physicalLimits = Limits(
        baseTone: -100...100, exposure: -100...100, contrast: -100...100,
        softness: 0...100, grain: 0...100, highlightShadow: -100...100,
        fade: 0...100, warmth: -100...100, tint: -100...100, mapping: 0...100
    )

    private static func clamp(
        _ adjustment: PhotoStylePlan.ToneAdjustment,
        to limits: Limits,
        region: Region,
        style: PhotoStyle,
        usesCustomPrompt: Bool
    ) -> PhotoStylePlan.ToneAdjustment {
        var output = adjustment
        output.baseTone = adjustment.baseTone.clamped(to: limits.baseTone)
        output.exposure = adjustment.exposure.clamped(to: usesCustomPrompt ? limits.exposure : exposureLimits(limits.exposure, region: region))
        output.contrast = adjustment.contrast.clamped(to: usesCustomPrompt ? limits.contrast : contrastLimits(limits.contrast, region: region, style: style))
        output.softness = adjustment.softness.clamped(to: limits.softness)
        output.grain = adjustment.grain.clamped(to: limits.grain)
        output.highlights = adjustment.highlights.clamped(to: limits.highlightShadow)
        output.shadows = adjustment.shadows.clamped(to: limits.highlightShadow)
        output.fade = adjustment.fade.clamped(to: limits.fade)
        output.warmth = adjustment.warmth.clamped(to: limits.warmth)
        output.tint = adjustment.tint.clamped(to: limits.tint)
        output.mapping = adjustment.mapping.clamped(to: limits.mapping)
        return output
    }

    private static func exposureLimits(_ limits: ClosedRange<Int>, region: Region) -> ClosedRange<Int> {
        guard region == .shadows else { return limits }
        return max(limits.lowerBound, -20)...limits.upperBound
    }

    private static func contrastLimits(
        _ limits: ClosedRange<Int>,
        region: Region,
        style: PhotoStyle
    ) -> ClosedRange<Int> {
        guard region == .shadows else { return limits }
        let ceiling = switch style {
        case .japaneseBWStrong:
            36
        case .fujiClassicNeg:
            30
        default:
            20
        }
        return limits.lowerBound...min(limits.upperBound, ceiling)
    }

    private static func limits(for style: PhotoStyle) -> Limits {
        switch style {
        case .autoDetection:
            return Limits(baseTone: -20...20, exposure: -60...60, contrast: -35...40, softness: 0...12, grain: 0...20, highlightShadow: -35...35, fade: 0...8, warmth: -40...40, tint: -35...35, mapping: 0...15)
        case .japaneseColor1:
            return Limits(baseTone: -22...2, exposure: -5...24, contrast: -16...10, softness: 0...14, grain: 0...14, highlightShadow: -8...30, fade: 0...16, warmth: -16...18, tint: -14...14, mapping: 20...70)
        case .japaneseColor2:
            return Limits(baseTone: -28...2, exposure: -2...26, contrast: -24...4, softness: 4...24, grain: 0...12, highlightShadow: -5...38, fade: 6...26, warmth: -10...20, tint: -6...18, mapping: 20...65)
        case .japaneseBWStrong:
            return Limits(baseTone: 0...0, exposure: -30...12, contrast: 10...50, softness: 0...8, grain: 10...50, highlightShadow: -25...30, fade: 0...6, warmth: 0...0, tint: 0...0, mapping: 35...80)
        case .japaneseBWStandard:
            return Limits(baseTone: 0...0, exposure: -18...16, contrast: -5...25, softness: 0...10, grain: 4...30, highlightShadow: -18...25, fade: 0...10, warmth: 0...0, tint: 0...0, mapping: 20...60)
        case .japaneseBWSoft:
            return Limits(baseTone: 0...0, exposure: -10...18, contrast: -24...4, softness: 6...26, grain: 2...20, highlightShadow: -10...28, fade: 2...18, warmth: 0...0, tint: 0...0, mapping: 15...55)
        case .fujiProvia:
            return Limits(baseTone: 2...24, exposure: -20...12, contrast: 2...24, softness: 0...5, grain: 0...10, highlightShadow: -12...20, fade: 0...3, warmth: -8...8, tint: -8...8, mapping: 15...55)
        case .fujiClassicChrome:
            return Limits(baseTone: -35...0, exposure: -20...12, contrast: -8...24, softness: 0...9, grain: 4...30, highlightShadow: -20...30, fade: 2...15, warmth: -20...18, tint: -18...15, mapping: 30...75)
        case .fujiClassicNeg:
            return Limits(baseTone: -20...10, exposure: -25...15, contrast: 10...40, softness: 0...8, grain: 8...32, highlightShadow: -20...32, fade: 0...8, warmth: -20...18, tint: -20...22, mapping: 35...80)
        default:
            return Limits(baseTone: -12...12, exposure: -30...30, contrast: -15...15, softness: 0...10, grain: 0...40, highlightShadow: -20...20, fade: 0...6, warmth: -12...12, tint: -12...12, mapping: 0...20)
        }
    }

}
