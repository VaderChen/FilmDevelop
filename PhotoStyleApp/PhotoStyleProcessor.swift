import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import PhotoStyleShared
import AppKit
#if canImport(Vision)
import Vision
#endif

enum PhotoStyleProcessor {
    private static let context = PhotoImageRenderPrecision.makeContext()

    static func repairedSource(_ image: PhotoImage, patches: [PhotoRepairPatch]) -> PhotoImage {
        guard !patches.isEmpty, let ci = CIImage(image: image) else { return image }
        let output = PhotoRepairPatch.applying(patches, to: ci.oriented(forExifOrientation: image.cgImageOrientation))
        return PhotoImageRenderPrecision.renderedImage(from: output, context: context, preserving: image) ?? image
    }

    static var canDetectSubjectMask: Bool {
        PhotoSubjectMaskGenerator.isAvailable
    }

    static func detectSubjectMask(for image: PhotoImage) -> CIImage? {
        guard let ciImage = CIImage(image: image) else {
            return nil
        }
        let oriented = ciImage.oriented(forExifOrientation: image.cgImageOrientation)
        let prepared = image.requiresRAWDisplayMapping
            ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(oriented)
            : oriented
        return makeSubjectMask(from: prepared, extent: prepared.extent)
    }

    static func apply(
        style: PhotoStyle,
        adjustment: StyleAdjustment,
        to image: PhotoImage,
        subjectMask: CIImage? = nil,
        shouldDetectSubjectMask: Bool = true,
        repairPatches: [PhotoRepairPatch] = [],
        isPreview: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> PhotoImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let source = ciImage.oriented(forExifOrientation: image.cgImageOrientation)
        let geometry = (adjustment.cropRect(in: source.extent, verticalAxisInverted: true),
                        PhotoCropCalculator.rotationTransform(in: source.extent, clockwiseDegrees: adjustment.cropRotation))
        let stages = ["physical-input", "input-calibration", "subject-mask", "skin-mask",
                      "skin-white-balance", "white-balance", "luminance-exposure", "light-scatter", "emulsion",
                      "development", "raw-display-mapping", "film-look", "skin-enhancement", "tone",
                      "tone-zones", "hdr", "crop-vignette", "depth-blur", "monochrome", "scanner"]
        let pipeline = PhotoProcessingPipeline(source: source,
            colorSpace: image.cgImage?.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            progress: progress.map { report in
                var reported = -1.0
                return { name, fraction in
                    guard let index = stages.firstIndex(of: name) else { return }
                    let value = (Double(index) + fraction) / Double(stages.count)
                    if value - reported >= 0.01 { reported = value; report(value) }
                }
            })
        let strength = effectiveStyleIntensity(from: adjustment.intensity)
        let effects = adjustment.filmEffects.clamped()
        let amounts = PhotoToneZoneProcessor.resolvedGrainAmounts(
            globalAmount: adjustment.grain / 100 * strength, highlightAmount: adjustment.highlightGrain / 100 * strength,
            midtoneAmount: adjustment.midtoneGrain / 100 * strength, shadowAmount: adjustment.shadowGrain / 100 * strength)
        do {
            try pipeline.process("physical-input") {
                // Patches stay in their saved original-image coordinates. Composite
                // first, then crop/rotate the whole image once; never remap patches.
                PhotoRepairPatch.applying(repairPatches, to: $0)
                    .transformed(by: geometry.1).cropped(to: geometry.0)
            }
            try pipeline.process("input-calibration") {
                PhotoColorCalibrationProcessor.apply(to: $0,
                    calibration: adjustment.colorCalibration?.stage == .input ? adjustment.colorCalibration : nil)
            }
            let resolvedSubjectMask = try pipeline.inspect("subject-mask") { input in
                subjectMask.map {
                    let fitted = $0.extent == source.extent ? $0 : PhotoSubjectMaskGenerator.fitMask($0, to: source.extent)
                    return fitted.transformed(by: geometry.1).cropped(to: input.extent)
                }
                    ?? (shouldDetectSubjectMask ? makeSubjectMask(from: input, extent: input.extent) : nil)
            }
            let whitening = adjustment.skinWhitening / 100 * strength
            let smoothing = adjustment.skinSmoothing / 100 * strength
            let warmth = adjustment.skinWarmth / 100 * strength
            let adjustsSkin = whitening > 0.005 || smoothing > 0.005 || abs(warmth) > 0.001
            let adjustsSkinWB = strength > 0 && !style.isMonochrome && style != .original && resolvedSubjectMask != nil
            var skinMask: CIImage?
            if adjustsSkin || adjustsSkinWB {
                // Both skin operations use the same pre-WB mask. Store just its
                // scalar samples; retaining its lazy graph would retain an old buffer.
                skinMask = try pipeline.inspect("skin-mask") {
                    try pipeline.mask(makeSkinMask(from: $0, subjectMask: resolvedSubjectMask, extent: $0.extent))
                }
                if adjustsSkinWB, let skinMask {
                    try pipeline.process("skin-white-balance") {
                        blend(applySkinWhiteBalance(to: $0, skinMask: skinMask, context: pipeline.context), with: $0, intensity: strength)
                    }
                }
            }
            try pipeline.process("white-balance") {
                applyWhiteBalanceAdjustment(to: $0, warmth: adjustment.whiteBalanceWarmth * strength,
                                            tint: adjustment.whiteBalanceTint * strength)
            }
            try pipeline.process("luminance-exposure") {
                PhotoFilmEffectsProcessor.applyExposure(to: $0, effects: effects)
            }
            try pipeline.process("light-scatter") {
                PhotoFilmEffectsProcessor.applyLightScatter(to: $0, effects: effects, strength: strength)
            }
            try pipeline.process("emulsion") {
                PhotoEmulsionExposureProcessor.apply(to: $0, effects: effects, amounts: amounts,
                    strength: strength, monochrome: style.isMonochrome, renderContext: pipeline.context,
                    sampling: isPreview ? .preview : .reference)
            }
            try pipeline.process("development") {
                PhotoFilmDevelopmentProcessor.apply(to: $0, effects: effects, strength: strength)
            }
            try pipeline.process("raw-display-mapping") {
                image.requiresRAWDisplayMapping && style.filmStock == nil && style != .original
                    ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments($0) : $0
            }
            try pipeline.process("film-look") {
                applyLook(to: $0, style: style, adjustment: adjustment, strength: strength, isRAW: image.requiresRAWDisplayMapping)
            }
            if adjustsSkin, let skinMask {
                try pipeline.process("skin-enhancement") {
                    PhotoSkinEnhancementProcessor.apply(to: $0, skinMask: skinMask, whitening: whitening,
                        smoothing: smoothing, profile: .app, warmth: warmth)
                }
            }
            try pipeline.process("tone") {
                let planned = applyPlanToneSemantics(to: applyDenoise(to: $0, amount: adjustment.denoise / 100 * strength), style: style, toneZones: adjustment.sourceToneZones, strength: strength)
                return applyGlobalToneAdjustment(to: applyExposure(to: planned, amount: adjustment.exposure * strength, renderContext: pipeline.context),
                                                 adjustment: adjustment, strength: strength, renderContext: pipeline.context)
            }
            try pipeline.process("tone-zones") {
                applyToneZoneAdjustments(to: $0, style: style, adjustment: adjustment, strength: strength)
            }
            try pipeline.process("hdr") {
                PhotoHDRProcessor.apply(to: $0, curve: adjustment.hdrToneCurve ?? PhotoHDRProcessor.manualCurve,
                                        amount: adjustment.hdrAmount / 100, renderContext: pipeline.context)
            }
            try pipeline.process("crop-vignette") {
                let devignetted = PhotoVignetteProcessor.applyDevignette(to: $0, amount: adjustment.devignette / 100 * strength, profile: .app)
                return PhotoVignetteProcessor.applyVignette(to: devignetted, amount: adjustment.vignette / 100 * strength, profile: .app)
            }
            if adjustment.backgroundBlur > 0 {
                try pipeline.process("depth-blur") {
                    let repaired = PhotoRepairPatch.applying(repairPatches, to: source)
                    return applyDepthLensBlur(to: $0,
                        sourceForDepth: image.requiresRAWDisplayMapping ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(repaired) : repaired,
                        subjectMask: resolvedSubjectMask,
                        amount: adjustment.backgroundBlur / 100, sourceImage: image.cgImage,
                        allowSubjectDetection: shouldDetectSubjectMask, geometryTransform: geometry.1,
                        depthRevision: repairPatches.map { $0.id.uuidString }.joined())
                }
            }
            if style.isMonochrome {
                try pipeline.process("monochrome") { PhotoImageEffectsProcessor.monochrome($0, profile: .desaturate) }
            }
            if style.filmStock != nil || style == .original {
                try pipeline.process("scanner") { input in
                    var scanning = effects
                    if scanning.scannerProfile == .off { scanning.scannerProfile = .neutral }
                    // Negative sensor flare is part of dye reconstruction; do not apply it twice.
                    if let stock = style.filmStock, scanning.scannerSource == .film || stock.family == "reversal" {
                        scanning.scanFlare = 0
                    }
                    let scanned = PhotoPositiveScannerProcessor.apply(to: input, effects: scanning)
                    let toned = style.isMonochrome ? PhotoImageEffectsProcessor.monochrome(scanned, profile: .desaturate) : scanned
                    return blend(toned, with: input, intensity: strength)
                }
            }
            let output = renderDecorations(on: try pipeline.finish(), adjustment: adjustment)
            progress?(1)
            return output
        } catch {
            // The caller checks cancellation before publishing or encoding.
            return image
        }
    }

    private static func applyLook(to correctedBaseImage: CIImage, style: PhotoStyle,
                                  adjustment: StyleAdjustment, strength: Double, isRAW: Bool) -> CIImage {
        // 曝光已在底片前的亮度階段套用，所有底片／相機／原片分支皆避免重複曝光。
        var adjustment = adjustment
        adjustment.filmEffects.clearPrintExposure()
        if style.cameraProfile != nil { adjustment.filmEffects.scannerProfile = .off }
        if (style.filmStock != nil || style == .original) && adjustment.filmEffects.scannerProfile == .off {
            adjustment.filmEffects.scannerProfile = .neutral
        }
        let monochromeSource = style.isMonochrome && style.filmStock == nil
            ? PhotoFilmEffectsProcessor.applyMonochromeFilter(to: correctedBaseImage, effects: adjustment.filmEffects, strength: strength)
            : correctedBaseImage
        let styleBaseImage = style.isMonochrome
            ? applyMonochrome(to: monochromeSource, style: style)
            : correctedBaseImage
        let filtered: CIImage

        switch style {
        case .original:
            filtered = correctedBaseImage
        case .autoDetection:
            filtered = correctedBaseImage
        case .japaneseColor1:
            filtered = applyJapaneseColor1Signature(to: correctedBaseImage)
        case .japaneseColor2:
            filtered = applyJapaneseColor2Signature(to: correctedBaseImage)
        case .japaneseBWStrong:
            filtered = styleBaseImage
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.24])
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0.00, y: 0.000),
                    "inputPoint1": CIVector(x: 0.24, y: 0.175),
                    "inputPoint2": CIVector(x: 0.50, y: 0.490),
                    "inputPoint3": CIVector(x: 0.78, y: 0.840),
                    "inputPoint4": CIVector(x: 1.00, y: 1.000)
                ])
        case .japaneseBWStandard:
            filtered = applyColorControls(to: styleBaseImage, saturation: 0, brightness: 0.002, contrast: 1.08)
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.84,
                    "inputShadowAmount": 0.08
                ])
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0.00, y: 0.008),
                    "inputPoint1": CIVector(x: 0.22, y: 0.190),
                    "inputPoint2": CIVector(x: 0.50, y: 0.500),
                    "inputPoint3": CIVector(x: 0.78, y: 0.805),
                    "inputPoint4": CIVector(x: 1.00, y: 0.990)
                ])
        case .japaneseBWSoft:
            filtered = applyColorControls(to: styleBaseImage, saturation: 0, brightness: 0.008, contrast: 0.94)
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.72,
                    "inputShadowAmount": 0.22
                ])
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0.00, y: 0.018),
                    "inputPoint1": CIVector(x: 0.22, y: 0.205),
                    "inputPoint2": CIVector(x: 0.50, y: 0.495),
                    "inputPoint3": CIVector(x: 0.80, y: 0.805),
                    "inputPoint4": CIVector(x: 1.00, y: 0.982)
                ])
        case .fujiProvia:
            filtered = applyColorControls(to: correctedBaseImage, saturation: 1.16, brightness: 0.004, contrast: 1.09)
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6600, y: 4)
                ])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.24])
        case .fujiClassicChrome:
            filtered = applyFujiClassicChromeSignature(to: correctedBaseImage)
        case .fujiClassicNeg:
            filtered = applyFujiClassicNegSignature(to: correctedBaseImage)
        default:
            if let stock = style.filmStock {
                // Sensitivity weights must see RGB before any grayscale conversion.
                let developed = PhotoFilmStockProcessor.apply(to: monochromeSource, stock: stock,
                                                             effects: adjustment.filmEffects, strength: strength, deferScannerRendering: true)
                filtered = PhotoFilmCharacterProcessor.apply(to: developed, stock: stock)
            } else if let camera = style.cameraProfile {
                filtered = PhotoCameraProcessor.apply(to: monochromeSource, profile: camera)
            } else {
                filtered = correctedBaseImage
            }
        }

        // Strength adjusts the monochrome look against a neutral grayscale base,
        // so reducing it never restores source color or retains the noir signature.
        let neutralSource = isRAW && style.filmStock != nil
            ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(monochromeSource)
            : monochromeSource
        let blendBaseImage = style.isMonochrome
            ? PhotoImageEffectsProcessor.monochrome(neutralSource, profile: .desaturate)
            : neutralSource
        // 一般風格共用中性印相處理；底片已在光譜成像中完成印相。
        let printed = style.filmStock == nil
            ? PhotoFilmEffectsProcessor.applyPrint(to: filtered, effects: adjustment.filmEffects)
            : filtered
        let blended = PhotoColorCalibrationProcessor.apply(to: blend(printed, with: blendBaseImage, intensity: strength),
            calibration: adjustment.colorCalibration?.stage == .output ? adjustment.colorCalibration : nil)
        return blended
    }

    private static func applyColorControls(
        to image: CIImage,
        saturation: Double,
        brightness: Double,
        contrast: Double
    ) -> CIImage {
        PhotoImageEffectsProcessor.colorControls(
            image,
            saturation: saturation,
            brightness: brightness,
            contrast: contrast
        )
    }

    private static func applyJapaneseColor1Signature(to image: CIImage) -> CIImage {
        var output = applyColorControls(to: image, saturation: 0.90, brightness: 0.006, contrast: 0.95)
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.94,
                "inputShadowAmount": 0.22
            ])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6700, y: -4)
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.022),
                "inputPoint1": CIVector(x: 0.22, y: 0.245),
                "inputPoint2": CIVector(x: 0.50, y: 0.520),
                "inputPoint3": CIVector(x: 0.80, y: 0.840),
                "inputPoint4": CIVector(x: 1.00, y: 0.995)
            ])

        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .shadows,
            redBias: -0.010,
            greenBias: 0.006,
            blueBias: 0.014,
            opacity: 0.36
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .midtones,
            redBias: -0.002,
            greenBias: 0.004,
            blueBias: 0.006,
            opacity: 0.22
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .highlights,
            redBias: 0.010,
            greenBias: 0.006,
            blueBias: -0.004,
            opacity: 0.20
        )
        return output
    }

    private static func applyJapaneseColor2Signature(to image: CIImage) -> CIImage {
        var output = applyColorControls(to: image, saturation: 0.82, brightness: 0.008, contrast: 0.91)
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.98,
                "inputShadowAmount": 0.28
            ])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6250, y: 2)
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.035),
                "inputPoint1": CIVector(x: 0.22, y: 0.260),
                "inputPoint2": CIVector(x: 0.50, y: 0.530),
                "inputPoint3": CIVector(x: 0.80, y: 0.860),
                "inputPoint4": CIVector(x: 1.00, y: 1.000)
            ])

        output = output.applyingFilter("CIBloom", parameters: [
            kCIInputRadiusKey: 7.0,
            kCIInputIntensityKey: 0.18
        ]).cropped(to: image.extent)

        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .shadows,
            redBias: 0.004,
            greenBias: -0.006,
            blueBias: 0.018,
            opacity: 0.28
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .midtones,
            redBias: 0.008,
            greenBias: -0.004,
            blueBias: 0.008,
            opacity: 0.22
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .highlights,
            redBias: 0.016,
            greenBias: 0.010,
            blueBias: -0.004,
            opacity: 0.22
        )
        return output
    }

    private static func applyFujiClassicChromeSignature(to image: CIImage) -> CIImage {
        var output = applyColorControls(to: image, saturation: 0.72, brightness: 0.000, contrast: 1.03)
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.84,
                "inputShadowAmount": 0.06
            ])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: -2)
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.010),
                "inputPoint1": CIVector(x: 0.22, y: 0.185),
                "inputPoint2": CIVector(x: 0.50, y: 0.495),
                "inputPoint3": CIVector(x: 0.80, y: 0.820),
                "inputPoint4": CIVector(x: 1.00, y: 0.985)
            ])

        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .shadows,
            redBias: -0.020,
            greenBias: 0.004,
            blueBias: 0.024,
            opacity: 0.48
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .highlights,
            redBias: -0.004,
            greenBias: 0.006,
            blueBias: 0.002,
            opacity: 0.20
        )
        return output
    }

    private static func applyFujiClassicNegSignature(to image: CIImage) -> CIImage {
        var output = applyColorControls(to: image, saturation: 1.02, brightness: 0.000, contrast: 1.10)
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.78,
                "inputShadowAmount": 0.02
            ])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.96, y: 0.018, z: 0.000, w: 0),
                "inputGVector": CIVector(x: 0.012, y: 1.010, z: 0.010, w: 0),
                "inputBVector": CIVector(x: 0.000, y: 0.022, z: 1.035, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.006, y: 0.004, z: 0.010, w: 0)
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.005),
                "inputPoint1": CIVector(x: 0.23, y: 0.170),
                "inputPoint2": CIVector(x: 0.50, y: 0.500),
                "inputPoint3": CIVector(x: 0.80, y: 0.840),
                "inputPoint4": CIVector(x: 1.00, y: 0.995)
            ])

        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .shadows,
            redBias: -0.028,
            greenBias: 0.016,
            blueBias: 0.030,
            opacity: 0.58
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .midtones,
            redBias: 0.002,
            greenBias: 0.000,
            blueBias: 0.002,
            opacity: 0.24
        )
        output = applyToneRegionColorCast(
            to: output,
            sourceForMask: image,
            region: .highlights,
            redBias: 0.018,
            greenBias: -0.012,
            blueBias: 0.016,
            opacity: 0.35
        )
        return output
    }

    private static func applyMonochrome(to image: CIImage, style: PhotoStyle) -> CIImage {
        PhotoImageEffectsProcessor.monochrome(
            image,
            profile: style == .japaneseBWStrong ? .noir : .desaturate
        )
    }

    private static func applyWhiteBalanceAdjustment(to image: CIImage, warmth: Double, tint: Double) -> CIImage {
        PhotoToneProcessor.applyTemperatureAndTint(
            to: image,
            warmth: warmth,
            tint: tint,
            profile: .app
        )
    }

    private static func blend(_ filtered: CIImage, with original: CIImage, intensity: Double) -> CIImage {
        PhotoImageEffectsProcessor.blend(filtered, with: original, opacity: intensity)
    }

    private static func applyExposure(to image: CIImage, amount: Double, renderContext: CIContext? = nil) -> CIImage {
        PhotoToneProcessor.applyExposure(to: image, ev: PhotoExposureScale.ev(fromSlider: amount), renderContext: renderContext)
    }

    private static func applyGlobalToneAdjustment(
        to image: CIImage,
        adjustment: StyleAdjustment,
        strength: Double,
        renderContext: CIContext? = nil
    ) -> CIImage {
        let contrastOffset = adjustment.contrast.clamped(to: -100...100) / 100 * strength
        let brightnessOffset = (adjustment.brightness.clamped(to: 0...100) - 50) / 50 * strength
        guard abs(contrastOffset) > 0.001 || abs(brightnessOffset) > 0.001 else {
            return image
        }

        let brightnessAdjusted = abs(brightnessOffset) > 0.001
            ? image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0,
                kCIInputBrightnessKey: brightnessOffset * 0.06,
                kCIInputContrastKey: 1.0
            ])
            : image
        return PhotoToneProcessor.applyContrast(
            to: brightnessAdjusted,
            amount: contrastOffset,
            renderContext: renderContext
        )
    }

    private static func applyPlanToneSemantics(
        to image: CIImage,
        style: PhotoStyle,
        toneZones: PhotoStylePlan.ToneZones?,
        strength: Double
    ) -> CIImage {
        guard let toneZones else { return image }
        let components: PhotoPlanToneComponents
        if style.isMonochrome {
            components = .appMonochromeSupplement
        } else if style == .autoDetection {
            components = .appAutoSupplement
        } else {
            components = .appSupplement
        }
        return PhotoPlanToneProcessor.apply(
            to: image,
            toneZones: toneZones,
            masks: PhotoToneMasks(input: image, profile: .layered),
            strength: strength,
            components: components
        )
    }

    private static func effectiveStyleIntensity(from sliderValue: Double) -> Double {
        sliderValue.clamped(to: 0...100) / 100
    }

    private typealias ToneRegion = PhotoToneRegion

    private struct ToneColorMapping {
        var saturation: Double
        var contrast: Double
        var brightness: Double
        var redBias: Double
        var greenBias: Double
        var blueBias: Double
        var blackLift: Double
        var whitePull: Double
    }

    private static func applyToneZoneAdjustments(
        to image: CIImage,
        style: PhotoStyle,
        adjustment: StyleAdjustment,
        strength: Double
    ) -> CIImage {
        let warmthScale = style.isMonochrome ? 0 : strength
        let shadowAdjusted = applyToneRegionAdjustment(
            to: image,
            style: style,
            region: .shadows,
            exposure: adjustment.shadowExposure * strength,
            intensity: adjustment.shadowIntensity * strength,
            warmth: adjustment.shadowWarmth * warmthScale
        )
        let midtoneAdjusted = applyToneRegionAdjustment(
            to: image,
            style: style,
            region: .midtones,
            exposure: adjustment.midtoneExposure * strength,
            intensity: adjustment.midtoneIntensity * strength,
            warmth: adjustment.midtoneWarmth * warmthScale
        )
        let highlightAdjusted = applyToneRegionAdjustment(
            to: image,
            style: style,
            region: .highlights,
            exposure: adjustment.highlightExposure * strength,
            intensity: adjustment.highlightIntensity * strength,
            warmth: adjustment.highlightWarmth * warmthScale
        )
        guard shadowAdjusted !== image || midtoneAdjusted !== image || highlightAdjusted !== image else { return image }
        return PhotoToneZoneProcessor.composite(
            base: image,
            shadows: shadowAdjusted,
            midtones: midtoneAdjusted,
            highlights: highlightAdjusted,
            masks: PhotoToneMasks(input: image, profile: .layered)
        )
    }

    private static func applyToneRegionAdjustment(
        to image: CIImage,
        style: PhotoStyle,
        region: ToneRegion,
        exposure: Double,
        intensity: Double,
        warmth: Double
    ) -> CIImage {
        let intensity = intensity.clamped(to: 0...100)
        guard abs(exposure) > 0.001 || intensity > 0.001 || abs(warmth) > 0.001 else {
            return image
        }

        var adjusted = applyExposure(to: image, amount: exposure)
        adjusted = applyWhiteBalanceAdjustment(to: adjusted, warmth: warmth, tint: 0)
        adjusted = applyToneRegionColorMapping(to: adjusted, style: style, region: region, intensity: intensity)
        return adjusted
    }

    private static func applyToneRegionColorMapping(
        to image: CIImage,
        style: PhotoStyle,
        region: ToneRegion,
        intensity: Double
    ) -> CIImage {
        let amount = (intensity.clamped(to: 0...100) / 100).clamped(to: 0...1)
        guard amount > 0.001 else { return image }

        let mapping = toneColorMapping(for: style, region: region)
        var mapped = image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: mapping.saturation,
                kCIInputBrightnessKey: mapping.brightness,
                kCIInputContrastKey: mapping.contrast
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: mapping.redBias, y: mapping.greenBias, z: mapping.blueBias, w: 0)
            ])

        if mapping.blackLift > 0.001 || mapping.whitePull > 0.001 {
            mapped = mapped.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: mapping.blackLift),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + mapping.blackLift * 0.45),
                "inputPoint2": CIVector(x: 0.50, y: 0.50),
                "inputPoint3": CIVector(x: 0.78, y: 0.78 - mapping.whitePull * 0.35),
                "inputPoint4": CIVector(x: 1.00, y: 1.00 - mapping.whitePull)
            ])
        }

        return blend(mapped, with: image, intensity: amount)
    }

    private static func toneColorMapping(for style: PhotoStyle, region: ToneRegion) -> ToneColorMapping {
        switch style {
        case .japaneseColor1:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.76, contrast: 1.04, brightness: 0.002, redBias: -0.026, greenBias: 0.012, blueBias: 0.028, blackLift: 0.014, whitePull: 0.004)
            case .midtones:
                return ToneColorMapping(saturation: 0.78, contrast: 1.03, brightness: 0.001, redBias: -0.012, greenBias: 0.012, blueBias: 0.006, blackLift: 0.010, whitePull: 0.004)
            case .highlights:
                return ToneColorMapping(saturation: 0.74, contrast: 1.01, brightness: 0.002, redBias: 0.012, greenBias: 0.006, blueBias: -0.010, blackLift: 0.000, whitePull: 0.014)
            }
        case .japaneseColor2:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.82, contrast: 1.01, brightness: 0.000, redBias: -0.006, greenBias: 0.000, blueBias: 0.008, blackLift: 0.008, whitePull: 0.002)
            case .midtones:
                return ToneColorMapping(saturation: 0.84, contrast: 1.01, brightness: 0.002, redBias: 0.014, greenBias: 0.003, blueBias: 0.010, blackLift: 0.004, whitePull: 0.004)
            case .highlights:
                return ToneColorMapping(saturation: 0.80, contrast: 0.99, brightness: 0.003, redBias: 0.018, greenBias: 0.008, blueBias: 0.002, blackLift: 0.000, whitePull: 0.010)
            }
        case .fujiProvia:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 1.10, contrast: 1.08, brightness: -0.004, redBias: -0.008, greenBias: 0.012, blueBias: 0.018, blackLift: 0.008, whitePull: 0.000)
            case .midtones:
                return ToneColorMapping(saturation: 1.16, contrast: 1.10, brightness: 0.002, redBias: 0.004, greenBias: 0.010, blueBias: 0.004, blackLift: 0.000, whitePull: 0.000)
            case .highlights:
                return ToneColorMapping(saturation: 1.06, contrast: 1.04, brightness: 0.006, redBias: 0.002, greenBias: 0.004, blueBias: 0.006, blackLift: 0.000, whitePull: 0.018)
            }
        case .fujiClassicChrome:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.74, contrast: 0.98, brightness: 0.002, redBias: -0.018, greenBias: 0.002, blueBias: 0.022, blackLift: 0.034, whitePull: 0.008)
            case .midtones:
                return ToneColorMapping(saturation: 0.70, contrast: 0.96, brightness: 0.000, redBias: -0.010, greenBias: 0.002, blueBias: 0.008, blackLift: 0.020, whitePull: 0.012)
            case .highlights:
                return ToneColorMapping(saturation: 0.70, contrast: 0.96, brightness: 0.002, redBias: -0.004, greenBias: 0.004, blueBias: 0.002, blackLift: 0.004, whitePull: 0.018)
            }
        case .fujiClassicNeg:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.94, contrast: 1.12, brightness: -0.006, redBias: -0.030, greenBias: 0.018, blueBias: 0.030, blackLift: 0.005, whitePull: 0.002)
            case .midtones:
                return ToneColorMapping(saturation: 1.06, contrast: 1.10, brightness: 0.000, redBias: 0.002, greenBias: 0.000, blueBias: 0.002, blackLift: 0.000, whitePull: 0.002)
            case .highlights:
                return ToneColorMapping(saturation: 0.96, contrast: 1.08, brightness: 0.002, redBias: 0.016, greenBias: -0.012, blueBias: 0.014, blackLift: 0.000, whitePull: 0.008)
            }
        case .japaneseBWStrong:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.00, contrast: 1.24, brightness: -0.010, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.000, whitePull: 0.000)
            case .midtones:
                return ToneColorMapping(saturation: 0.00, contrast: 1.18, brightness: 0.000, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.000, whitePull: 0.000)
            case .highlights:
                return ToneColorMapping(saturation: 0.00, contrast: 1.12, brightness: 0.008, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.000, whitePull: 0.006)
            }
        case .japaneseBWStandard:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.00, contrast: 0.98, brightness: 0.004, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.015, whitePull: 0.000)
            case .midtones:
                return ToneColorMapping(saturation: 0.00, contrast: 1.04, brightness: 0.002, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.012, whitePull: 0.004)
            case .highlights:
                return ToneColorMapping(saturation: 0.00, contrast: 1.02, brightness: 0.004, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.000, whitePull: 0.016)
            }
        case .japaneseBWSoft:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.00, contrast: 0.92, brightness: 0.004, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.025, whitePull: 0.006)
            case .midtones:
                return ToneColorMapping(saturation: 0.00, contrast: 0.90, brightness: 0.004, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.015, whitePull: 0.010)
            case .highlights:
                return ToneColorMapping(saturation: 0.00, contrast: 0.90, brightness: 0.004, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.005, whitePull: 0.022)
            }
        case .autoDetection:
            switch region {
            case .shadows:
                return ToneColorMapping(saturation: 0.98, contrast: 0.96, brightness: 0.004, redBias: -0.006, greenBias: 0.004, blueBias: 0.006, blackLift: 0.018, whitePull: 0.000)
            case .midtones:
                return ToneColorMapping(saturation: 1.00, contrast: 1.00, brightness: 0.000, redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0.000, whitePull: 0.000)
            case .highlights:
                return ToneColorMapping(saturation: 0.98, contrast: 0.96, brightness: 0.002, redBias: 0.004, greenBias: 0.002, blueBias: -0.004, blackLift: 0.000, whitePull: 0.012)
            }
        default:
            // Optional local print trim; stock defaults keep mapping at zero.
            // Do not run the stock density curve a second time or add a new cast.
            let family = style.filmStock?.family ?? "negative"
            let contrast = family == "creative" ? 1.10 : (family == "monochrome" ? 1.06 : 1.04)
            let saturation = style.isMonochrome ? 0.0 : (family == "reversal" ? 1.06 : 1.02)
            return ToneColorMapping(saturation: saturation, contrast: contrast, brightness: 0,
                                    redBias: 0, greenBias: 0, blueBias: 0, blackLift: 0, whitePull: 0)
        }
    }

    private static func applyToneRegionColorCast(
        to image: CIImage,
        sourceForMask: CIImage,
        region: ToneRegion,
        redBias: Double,
        greenBias: Double,
        blueBias: Double,
        opacity: Double
    ) -> CIImage {
        let colorCasted = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: redBias, y: greenBias, z: blueBias, w: 0)
        ])

        let mask = applyMaskOpacity(
            to: makeToneMask(from: sourceForMask, region: region),
            opacity: opacity
        )
        return PhotoToneZoneProcessor.blend(colorCasted, over: image, mask: mask)
    }

    private static func makeToneMask(from image: CIImage, region: ToneRegion) -> CIImage {
        PhotoToneMasks.mask(from: image, region: region, profile: .layered)
    }

    private static func applySkinWhiteBalance(
        to image: CIImage,
        skinMask: CIImage,
        context: CIContext
    ) -> CIImage {
        let extent = image.extent
        guard let average = maskedAverageRGB(of: image, mask: skinMask, extent: extent, context: context) else {
            return image
        }

        let lowerConfidence = ((average.coverage - 0.02) / 0.08).clamped(to: 0...1)
        let upperConfidence = ((0.55 - average.coverage) / 0.15).clamped(to: 0...1)
        let confidence = min(lowerConfidence, upperConfidence)
        guard confidence > 0.05 else { return image }

        let green = max(average.g, 0.001)
        let redRatio = average.r / green
        let blueRatio = average.b / green

        let targetRedRatio = 1.18
        let targetBlueRatio = 0.82
        let correctionStrength = 0.55 * confidence
        var redGain = (1 + (targetRedRatio / max(redRatio, 0.001) - 1) * correctionStrength).clamped(to: 0.88...1.12)
        var greenGain = 1.0
        var blueGain = (1 + (targetBlueRatio / max(blueRatio, 0.001) - 1) * correctionStrength).clamped(to: 0.88...1.12)

        let sourceLuma = max(0.001, 0.2126 * average.r + 0.7152 * average.g + 0.0722 * average.b)
        let correctedLuma = max(0.001, 0.2126 * average.r * redGain + 0.7152 * average.g + 0.0722 * average.b * blueGain)
        let lumaScale = (sourceLuma / correctedLuma).clamped(to: 0.92...1.08)
        redGain = (redGain * lumaScale).clamped(to: 0.86...1.14)
        greenGain = (greenGain * lumaScale).clamped(to: 0.86...1.14)
        blueGain = (blueGain * lumaScale).clamped(to: 0.86...1.14)

        guard max(abs(redGain - 1), abs(greenGain - 1), abs(blueGain - 1)) > 0.012 else {
            return image
        }

        let corrected = applyChannelGains(to: image, red: redGain, green: greenGain, blue: blueGain)
        let global = blend(corrected, with: image, intensity: 0.16 * confidence)
        return corrected.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: global,
            kCIInputMaskImageKey: applyMaskOpacity(to: skinMask, opacity: 0.58 * confidence)
        ])
    }

    private static func applyChannelGains(to image: CIImage, red: Double, green: Double, blue: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private static func maskedAverageRGB(
        of image: CIImage,
        mask: CIImage,
        extent: CGRect,
        context: CIContext
    ) -> (r: Double, g: Double, b: Double, coverage: Double)? {
        let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])

        guard let weightedAverage = areaAverageRGBA(weighted, extent: extent, context: context),
              let maskAverage = areaAverageRGBA(mask, extent: extent, context: context),
              maskAverage.r > 0.02,
              maskAverage.r < 0.55 else {
            return nil
        }

        return (
            r: (weightedAverage.r / maskAverage.r).clamped(to: 0...1),
            g: (weightedAverage.g / maskAverage.r).clamped(to: 0...1),
            b: (weightedAverage.b / maskAverage.r).clamped(to: 0...1),
            coverage: maskAverage.r
        )
    }

    private static func areaAverageRGBA(_ image: CIImage, extent: CGRect, context: CIContext) -> (r: Double, g: Double, b: Double, a: Double)? {
        if extent.width * extent.height > 512 * 512 {
            var total = SIMD4<Double>(repeating: 0)
            let area = extent.width * extent.height
            let edge = 512
            for y in stride(from: extent.minY, to: extent.maxY, by: CGFloat(edge)) {
                for x in stride(from: extent.minX, to: extent.maxX, by: CGFloat(edge)) {
                    if Task.isCancelled { return nil }
                    let values: [Float]? = autoreleasepool {
                        let rect = CGRect(x: x, y: y, width: min(CGFloat(edge), extent.maxX-x), height: min(CGFloat(edge), extent.maxY-y))
                        let filter = CIFilter.areaAverage()
                        filter.inputImage = image; filter.extent = rect
                        var values = [Float](repeating: 0, count: 4)
                        guard let output = filter.outputImage else { return nil }
                        context.render(output, toBitmap: &values, rowBytes: 16,
                            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                        let weight = Double(rect.width * rect.height / area)
                        for c in 0..<4 { total[c] += Double(values[c]) * weight }
                        return values
                    }
                    guard values != nil else { return nil }
                }
            }
            let floats = (0..<4).map { Float(total[$0]) }
            let pixel = CIImage(bitmapData: floats.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                size: CGSize(width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            var converted = [Float](repeating: 0, count: 4)
            context.render(pixel, toBitmap: &converted, rowBytes: 16, bounds: pixel.extent, format: .RGBAf,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            return (Double(converted[0]),Double(converted[1]),Double(converted[2]),Double(converted[3]))
        }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent
        guard let output = filter.outputImage else {
            return nil
        }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (
            r: Double(pixel[0]),
            g: Double(pixel[1]),
            b: Double(pixel[2]),
            a: Double(pixel[3])
        )
    }

    private static func makeSkinMask(from image: CIImage, subjectMask: CIImage?, extent: CGRect) -> CIImage {
        PhotoSkinMaskGenerator.make(from: image, personMask: subjectMask, profile: .app)
    }

    private static func makeSubjectMask(from image: CIImage, extent: CGRect) -> CIImage? {
        PhotoSubjectMaskGenerator.makeMask(from: image)
    }

    private static func applyMaskOpacity(to mask: CIImage, opacity: Double) -> CIImage {
        PhotoMaskProcessor.opacity(mask, value: opacity)
    }

    private static func applyDenoise(to image: CIImage, amount: Double) -> CIImage {
        PhotoNoiseProcessor.denoise(image, amount: amount)
    }


    private static func applyDepthLensBlur(
        to image: CIImage,
        sourceForDepth: CIImage,
        subjectMask: CIImage?,
        amount: Double,
        sourceImage: CGImage?,
        allowSubjectDetection: Bool,
        geometryTransform: CGAffineTransform = .identity,
        depthRevision: String = ""
    ) -> CIImage {
        let amount = amount.clamped(to: 0...1)
        guard amount > 0.005 else { return image }
        guard let subjectMask,
              let depthMap = DepthAnythingV2DepthEstimator.shared.depthMap(
                for: sourceForDepth,
                sourceImage: sourceImage, revision: depthRevision
              ) else {
            let fallbackMask = subjectMask ?? (allowSubjectDetection
                ? PhotoSubjectMaskGenerator.makeMask(from: sourceForDepth)?.transformed(by: geometryTransform) : nil)
            guard let fallbackMask else { return image }
            return PhotoBackgroundBlurProcessor.apply(
                to: image,
                personMask: fallbackMask,
                amount: amount
            )
        }
        let croppedDepthMap = depthMap.transformed(by: geometryTransform).cropped(to: image.extent)
        guard let plan = depthBlurPlan(for: croppedDepthMap, subjectMask: subjectMask, extent: image.extent),
              let blurMask = depthBlurMask(from: croppedDepthMap, plan: plan, amount: amount) else {
            return PhotoBackgroundBlurProcessor.apply(
                to: image,
                personMask: subjectMask,
                amount: amount
            )
        }

        return PhotoBackgroundBlurProcessor.apply(
            to: image, personMask: subjectMask, amount: amount, depthMask: blurMask
        )
    }

    static func depthBlurPlan(for depthMap: CIImage, subjectMask: CIImage, extent: CGRect) -> PhotoDepthBlurPlan? {
        let maxSide = 96.0
        let scale = min(1.0, maxSide / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let sampleBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let toSampleSpace = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: -extent.minX * scale, ty: -extent.minY * scale
        )
        let sampledDepth = depthMap
            .transformed(by: toSampleSpace)
            .cropped(to: sampleBounds)

        guard let depthPixels = renderFloatPixels(sampledDepth, bounds: sampleBounds) else {
            return nil
        }
        let sampledMask = subjectMask
            .transformed(by: toSampleSpace)
            .cropped(to: sampleBounds)
        guard let maskPixels = renderFloatPixels(sampledMask, bounds: sampleBounds) else {
            return nil
        }

        return PhotoDepthBlurPlanner.makePlan(
            depthPixels: depthPixels,
            maskPixels: maskPixels,
            width: width,
            height: height
        )
    }

    private static func renderFloatPixels(_ image: CIImage, bounds: CGRect) -> [Float]? {
        let width = max(1, Int(bounds.width.rounded()))
        let height = max(1, Int(bounds.height.rounded()))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let rowBytes = width * 4 * MemoryLayout<Float>.size
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: rowBytes,
            bounds: bounds,
            format: .RGBAf,
            colorSpace: nil
        )
        return pixels
    }

    static func depthBlurMask(from depthMap: CIImage, plan: PhotoDepthBlurPlan, amount: Double) -> CIImage? {
        let range = max(plan.maxDepth - plan.minDepth, 0.0001)
        let focusDepth = ((plan.focusDepth - plan.minDepth) / range).clamped(to: 0...1)
        let deadZone = max(0.035, 0.13 - amount * 0.055)
        let gain = 1.35 + amount * 1.65

        // Keep the two clamps separate so outliers cannot change the
        // foreground/background boundary.
        // Built-in filters run through Core Image's current rendering backend
        // without compiling the deprecated Core Image Kernel Language at runtime.
        func remap(_ image: CIImage, scale: Double, bias: Double) -> CIImage? {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            let vector = CIVector(x: scale, y: 0, z: 0, w: 0)
            matrix.rVector = vector
            matrix.gVector = vector
            matrix.bVector = vector
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
            guard let mapped = matrix.outputImage else { return nil }

            let clamp = CIFilter.colorClamp()
            clamp.inputImage = mapped
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            return clamp.outputImage
        }

        let distanceScale = gain / max(0.001, 1.0 - deadZone)
        // CIColorMatrix unpremultiplies its input. Compensate so it reads the
        // original red sample even if a supplied depth map has partial alpha.
        guard let normalized = remap(depthMap.premultiplyingAlpha(), scale: 1.0 / range, bias: -plan.minDepth / range),
              let distance = remap(
                normalized,
                scale: plan.backgroundDirection * distanceScale,
                bias: (-focusDepth * plan.backgroundDirection - deadZone) * distanceScale
              ) else { return nil }

        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = distance
        gamma.power = 0.72
        return gamma.outputImage?.cropped(to: depthMap.extent)
    }

    final class DepthAnythingV2DepthEstimator {
        static let shared = DepthAnythingV2DepthEstimator()

        private let lock = NSLock()
        private var model: MLModel?
        private var unavailable = false
        // Keep the identity object alive; an address alone can be reused for a
        // newly opened image and accidentally return the previous depth map.
        private var cachedDepthMaps: [(source: CGImage, extent: CGRect, revision: String, depth: CIImage)] = []

        func depthMap(for image: CIImage, sourceImage: CGImage?, revision: String = "") -> CIImage? {
            lock.lock()
            defer { lock.unlock() }
            guard !unavailable else { return nil }
            if let sourceImage, let cached = cachedDepthMaps.first(where: {
                $0.source === sourceImage && $0.extent == image.extent && $0.revision == revision
            }) {
                return cached.depth
            }

            do {
                let model = try loadModel()
                guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
                    return nil
                }
                // 保持照片直立，等比例縮放後補邊；推論完成再去除補邊。
                let bounds = image.extent
                let scale = min(CGFloat(constraint.pixelsWide) / bounds.width,
                                CGFloat(constraint.pixelsHigh) / bounds.height)
                let fittedSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let fitRect = CGRect(x: (CGFloat(constraint.pixelsWide) - fittedSize.width) / 2,
                                     y: (CGFloat(constraint.pixelsHigh) - fittedSize.height) / 2,
                                     width: fittedSize.width, height: fittedSize.height)
                let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                    tx: fitRect.minX - bounds.minX * scale, ty: fitRect.minY - bounds.minY * scale)
                let inferenceImage = image.transformed(by: transform).clampedToExtent().cropped(to:
                    CGRect(x: 0, y: 0, width: constraint.pixelsWide, height: constraint.pixelsHigh))
                guard let cgImage = context.createCGImage(inferenceImage, from: inferenceImage.extent) else { return nil }
                let inputImage = try MLFeatureValue(cgImage: cgImage, constraint: constraint,
                    options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
                let input = try MLDictionaryFeatureProvider(dictionary: ["image": inputImage])
                let output = try model.prediction(from: input)
                guard let depthBuffer = output.featureValue(for: "depth")?.imageBufferValue else {
                    return nil
                }

                let depth = PhotoSubjectMaskGenerator.fitMask(
                    CIImage(cvPixelBuffer: depthBuffer), to: inferenceImage.extent
                ).cropped(to: fitRect)
                let fittedDepth = PhotoSubjectMaskGenerator.fitMask(depth, to: image.extent)
                if let sourceImage {
                    cachedDepthMaps.insert((sourceImage, image.extent, revision, fittedDepth), at: 0)
                    // 拖曳預覽與處理圖各留一份，避免切換解析度就重新推論。
                    if cachedDepthMaps.count > 2 { cachedDepthMaps.removeLast() }
                }
                return fittedDepth
            } catch {
                // 單張照片或暫時的推論失敗不應永久停用整個工作階段。
                return nil
            }
        }

        private func loadModel() throws -> MLModel {
            if let model { return model }

            let configuration = MLModelConfiguration()
            #if arch(arm64)
            configuration.computeUnits = .all
            #else
            configuration.computeUnits = .cpuOnly
            #endif

            if let compiledURL = Bundle.main.url(
                forResource: "DepthAnythingV2SmallF16P6",
                withExtension: "mlmodelc",
                subdirectory: "Models"
            ) {
                let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
                model = loaded
                return loaded
            }

            guard let packageURL = Bundle.main.url(
                forResource: "DepthAnythingV2SmallF16P6",
                withExtension: "mlpackage",
                subdirectory: "Models"
            ) else {
                unavailable = true
                throw PhotoStyleDepthError.modelNotFound
            }

            let compiledURL = try MLModel.compileModel(at: packageURL)
            let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
            model = loaded
            return loaded
        }
    }

    private enum PhotoStyleDepthError: Error {
        case modelNotFound
    }

    static func renderedOutputSize(for sourceSize: CGSize, adjustment: StyleAdjustment) -> CGSize {
        let cropped = adjustment.cropRect(in: CGRect(origin: .zero, size: sourceSize)).integral.size
        return decoratedOutputSize(for: cropped, adjustment: adjustment)
    }

    private static func decoratedOutputSize(for imageSize: CGSize, adjustment: StyleAdjustment) -> CGSize {
        guard adjustment.frameEnabled else { return imageSize }
        let config = frameRenderConfig(for: adjustment.frameStyle, imageSize: imageSize)
        return CGSize(
            width: (imageSize.width + config.insets.left + config.insets.right).rounded(),
            height: (imageSize.height + config.insets.top + config.insets.bottom).rounded()
        )
    }

    private static func renderDecorations(on image: PhotoImage, adjustment: StyleAdjustment) -> PhotoImage {
        guard adjustment.frameEnabled || adjustment.dateEnabled else {
            return image
        }

        let sourceRect = CGRect(origin: .zero, size: image.size)
        let frameConfig = adjustment.frameEnabled ? frameRenderConfig(for: adjustment.frameStyle, imageSize: image.size) : nil
        let contentRect: CGRect
        let canvasSize: CGSize

        if let frameConfig {
            contentRect = CGRect(
                x: frameConfig.insets.left,
                y: frameConfig.insets.top,
                width: image.size.width,
                height: image.size.height
            )
            canvasSize = decoratedOutputSize(for: image.size, adjustment: adjustment)
        } else {
            contentRect = sourceRect
            canvasSize = image.size
        }

        return image.renderedCanvas(size: canvasSize) { context in
            let canvasRect = CGRect(origin: .zero, size: canvasSize)

            if let frameConfig {
                frameConfig.backgroundColor.setFill()
                context.fill(canvasRect)
                drawFrame(adjustment.frameStyle, canvas: canvasRect, content: contentRect, context: context)
            }

            image.draw(in: contentRect)

            if adjustment.dateEnabled {
                PhotoDateStampRenderer.draw(adjustment.dateStyle, in: contentRect, context: context)
            }
        }
    }

    private struct FrameRenderConfig {
        var insets: NSEdgeInsets
        var backgroundColor: NSColor
    }

    private static func frameRenderConfig(for style: FrameStyle, imageSize: CGSize) -> FrameRenderConfig {
        let shortSide = min(imageSize.width, imageSize.height)
        let thin = max(shortSide * 0.035, 14)
        let wide = max(shortSide * 0.085, 32)
        let polaroidSide = max(shortSide * 0.060, 24)
        let polaroidTop = max(shortSide * 0.060, 24)
        let polaroidBottom = max(shortSide * 0.220, 86)
        let filmSide = max(shortSide * 0.090, 34)

        switch style {
        case .whitePaperThin:
            return FrameRenderConfig(
                insets: NSEdgeInsets(top: thin, left: thin, bottom: thin, right: thin),
                backgroundColor: NSColor(white: 0.965, alpha: 1)
            )
        case .whitePaperWide:
            return FrameRenderConfig(
                insets: NSEdgeInsets(top: wide, left: wide, bottom: wide, right: wide),
                backgroundColor: NSColor(white: 0.965, alpha: 1)
            )
        case .whitePaperPolaroid:
            return FrameRenderConfig(
                insets: NSEdgeInsets(top: polaroidTop, left: polaroidSide, bottom: polaroidBottom, right: polaroidSide),
                backgroundColor: NSColor(white: 0.970, alpha: 1)
            )
        case .blackLine:
            let margin = max(shortSide * 0.030, 12)
            return FrameRenderConfig(
                insets: NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin),
                backgroundColor: NSColor(white: 0.035, alpha: 1)
            )
        case .filmStrip:
            let margin = max(shortSide * 0.025, 10)
            return FrameRenderConfig(
                insets: NSEdgeInsets(top: margin, left: filmSide, bottom: margin, right: filmSide),
                backgroundColor: NSColor(white: 0.030, alpha: 1)
            )
        case .cleanInset:
            let margin = max(shortSide * 0.055, 22)
            return FrameRenderConfig(
                insets: NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin),
                backgroundColor: NSColor(white: 0.955, alpha: 1)
            )
        }
    }

    private static func drawFrame(_ style: FrameStyle, canvas: CGRect, content: CGRect, context: CGContext) {
        let shortSide = min(content.width, content.height)
        let fine = max(shortSide * 0.004, 1.5)
        let medium = max(shortSide * 0.010, 3)

        switch style {
        case .whitePaperThin, .whitePaperWide, .whitePaperPolaroid:
            NSColor(white: 0.82, alpha: 0.28).setStroke()
            context.setLineWidth(fine)
            context.stroke(content.insetBy(dx: -fine * 0.5, dy: -fine * 0.5))
        case .blackLine:
            NSColor.black.withAlphaComponent(0.9).setStroke()
            context.setLineWidth(medium)
            context.stroke(content.insetBy(dx: -medium * 0.5, dy: -medium * 0.5))
        case .filmStrip:
            NSColor.white.withAlphaComponent(0.65).setFill()
            let stripWidth = max(content.minX, canvas.maxX - content.maxX)
            let perforationSize = CGSize(width: stripWidth * 0.34, height: stripWidth * 0.24)
            let gap = stripWidth * 0.62
            var y = canvas.minY + gap * 0.7
            while y < canvas.maxY - gap * 0.4 {
                context.fill(CGRect(
                    x: canvas.minX + stripWidth * 0.33,
                    y: y,
                    width: perforationSize.width,
                    height: perforationSize.height
                ))
                context.fill(CGRect(
                    x: canvas.maxX - stripWidth * 0.67,
                    y: y,
                    width: perforationSize.width,
                    height: perforationSize.height
                ))
                y += gap
            }
        case .cleanInset:
            NSColor(white: 0.72, alpha: 0.55).setStroke()
            context.setLineWidth(fine)
            context.stroke(content.insetBy(dx: -medium * 1.4, dy: -medium * 1.4))
        }
    }

}

private extension PhotoImage {
    var cgImageOrientation: Int32 {
        switch imageOrientation {
        case .up:
            return 1
        case .down:
            return 3
        case .left:
            return 8
        case .right:
            return 6
        case .upMirrored:
            return 2
        case .downMirrored:
            return 4
        case .leftMirrored:
            return 5
        case .rightMirrored:
            return 7
        @unknown default:
            return 1
        }
    }
}
