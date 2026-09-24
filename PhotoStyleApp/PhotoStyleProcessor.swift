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
        repairPatches: [PhotoRepairPatch] = []
    ) -> PhotoImage {
        guard let ciImage = CIImage(image: image) else {
            return image
        }

        let decoded = PhotoRepairPatch.applying(repairPatches, to: ciImage.oriented(forExifOrientation: image.cgImageOrientation))
        let strength = effectiveStyleIntensity(from: adjustment.intensity)
        // Scatter scene-linear highlight energy before RAW display companding.
        let cleanedInput = applyDenoise(to: decoded, amount: adjustment.denoise / 100 * strength)
        let calibratedInput = PhotoColorCalibrationProcessor.apply(to: cleanedInput,
            calibration: adjustment.colorCalibration?.stage == .input ? adjustment.colorCalibration : nil)
        let amounts = PhotoToneZoneProcessor.resolvedGrainAmounts(
            globalAmount: adjustment.grain / 100 * strength, highlightAmount: adjustment.highlightGrain / 100 * strength,
            midtoneAmount: adjustment.midtoneGrain / 100 * strength, shadowAmount: adjustment.shadowGrain / 100 * strength)
        let exposureGraph = PhotoFilmExposureProcessor.apply(to: calibratedInput, effects: adjustment.filmEffects,
            amounts: amounts, strength: strength, monochrome: style.isMonochrome)
        // 膚色統計與最終渲染共用同一曝光結果；僅昂貴的乳劑／顯影分支物化。
        let hasExposureEffects = amounts.shadows > 0 || amounts.midtones > 0 || amounts.highlights > 0
            || adjustment.filmEffects.halationAmount > 0 || adjustment.filmEffects.developmentAmount > 0
        let developed = hasExposureEffects ? exposureGraph.insertingIntermediate(cache: true) : exposureGraph
        // Film stocks own their exposure-to-density shoulder. Do not compress RAW
        // headroom before that curve; retain the legacy mapping for other looks.
        let oriented = image.requiresRAWDisplayMapping && style.filmStock == nil && style != .original
            ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(developed)
            : developed
        // 遮罩以固定預覽尺寸保存，套用時對齊目前原檔或縮小預覽的座標。
        let resolvedSubjectMask = subjectMask.map {
            $0.extent == oriented.extent ? $0 : PhotoSubjectMaskGenerator.fitMask($0, to: oriented.extent)
        } ?? (shouldDetectSubjectMask ? makeSubjectMask(from: oriented, extent: oriented.extent) : nil)
        let skinWhiteBalanced = style.isMonochrome || style == .original
            ? oriented
            : applySkinWhiteBalance(
                to: oriented,
                sourceForMask: oriented,
                subjectMask: resolvedSubjectMask
            )
        let whiteBalanced = blend(skinWhiteBalanced, with: oriented, intensity: strength)
        let baseImage = applySkinEnhancement(
            to: whiteBalanced,
            sourceForMask: oriented,
            subjectMask: resolvedSubjectMask,
            whitening: adjustment.skinWhitening / 100 * strength,
            smoothing: adjustment.skinSmoothing / 100 * strength,
            warmth: adjustment.skinWarmth / 100 * strength
        )
        let correctedBaseImage = applyWhiteBalanceAdjustment(
            to: baseImage,
            warmth: adjustment.whiteBalanceWarmth * strength,
            tint: adjustment.whiteBalanceTint * strength
        )
        let monochromeSource = style.isMonochrome && style.filmStock == nil
            ? PhotoFilmEffectsProcessor.applyMonochromeFilter(to: correctedBaseImage, effects: adjustment.filmEffects, strength: strength)
            : correctedBaseImage
        let styleBaseImage = style.isMonochrome
            ? applyMonochrome(to: monochromeSource, style: style)
            : correctedBaseImage
        let filtered: CIImage

        switch style {
        case .original:
            filtered = PhotoPositiveScannerProcessor.apply(to: correctedBaseImage, effects: adjustment.filmEffects)
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
                filtered = PhotoFilmStockProcessor.apply(to: monochromeSource, stock: stock,
                                                        effects: adjustment.filmEffects, strength: strength)
            } else if let camera = style.cameraProfile {
                let simulated = PhotoCameraProcessor.apply(to: monochromeSource, profile: camera)
                filtered = camera.isMonochrome ? simulated : PhotoPositiveScannerProcessor.apply(to: simulated, effects: adjustment.filmEffects)
            } else {
                filtered = correctedBaseImage
            }
        }

        // Strength adjusts the monochrome look against a neutral grayscale base,
        // so reducing it never restores source color or retains the noir signature.
        let neutralSource = image.requiresRAWDisplayMapping && style.filmStock != nil
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
        let planToneAdjusted = applyPlanToneSemantics(
            to: blended,
            style: style,
            toneZones: adjustment.sourceToneZones,
            strength: strength
        )
        let exposed = applyExposure(to: planToneAdjusted, amount: adjustment.exposure * strength)
        let toneAdjusted = applyGlobalToneAdjustment(to: exposed, adjustment: adjustment, strength: strength)
        let zoneAdjusted = applyToneZoneAdjustments(to: toneAdjusted, style: style, adjustment: adjustment, strength: strength)
        let hdrAdjusted = PhotoHDRProcessor.apply(
            to: zoneAdjusted,
            curve: adjustment.hdrToneCurve ?? PhotoHDRProcessor.manualCurve,
            amount: adjustment.hdrAmount / 100
        )
        let cropRect = adjustment.cropRect(in: hdrAdjusted.extent, verticalAxisInverted: true)
        let cropTransform = PhotoCropCalculator.rotationTransform(in: hdrAdjusted.extent, clockwiseDegrees: adjustment.cropRotation)
        let cropped = hdrAdjusted.transformed(by: cropTransform).cropped(to: cropRect)
        let croppedSubjectMask = resolvedSubjectMask?.transformed(by: cropTransform).cropped(to: cropRect)
        let devignetted = PhotoVignetteProcessor.applyDevignette(to: cropped, amount: adjustment.devignette / 100 * strength, profile: .app)
        let withVignette = PhotoVignetteProcessor.applyVignette(to: devignetted, amount: adjustment.vignette / 100 * strength, profile: .app)
        let withLensBlur = applyDepthLensBlur(
            to: withVignette,
            sourceForDepth: image.requiresRAWDisplayMapping
                ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(decoded) : decoded,
            subjectMask: croppedSubjectMask,
            amount: adjustment.backgroundBlur / 100,
            sourceImage: image.cgImage,
            allowSubjectDetection: shouldDetectSubjectMask,
            geometryTransform: cropTransform,
            depthRevision: repairPatches.map { $0.id.uuidString }.joined()
        )

        // Tone-plan fade and other adjustments can introduce a slight color cast.
        // Keep the photo monochrome while allowing colored frames/date decorations.
        let output = style.isMonochrome
            ? PhotoImageEffectsProcessor.monochrome(withLensBlur, profile: .desaturate)
            : withLensBlur
        guard let rendered = PhotoImageRenderPrecision.renderedImage(
            from: output.cropped(to: cropRect),
            context: context,
            highPrecision: false,
            colorSpace: image.cgImage?.colorSpace
        ) else {
            return image
        }
        return renderDecorations(on: rendered, adjustment: adjustment)
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

    private static func applyExposure(to image: CIImage, amount: Double) -> CIImage {
        PhotoToneProcessor.applyExposure(to: image, ev: PhotoExposureScale.ev(fromSlider: amount))
    }

    private static func applyGlobalToneAdjustment(
        to image: CIImage,
        adjustment: StyleAdjustment,
        strength: Double
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
            amount: contrastOffset
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

    private static func applySkinEnhancement(
        to image: CIImage,
        sourceForMask: CIImage,
        subjectMask: CIImage?,
        whitening: Double,
        smoothing: Double,
        warmth: Double
    ) -> CIImage {
        let whitening = whitening.clamped(to: 0...1)
        let smoothing = smoothing.clamped(to: 0...1)
        guard whitening > 0.005 || smoothing > 0.005 || abs(warmth) > 0.001 else { return image }

        let extent = image.extent
        let skinMask = makeSkinMask(from: sourceForMask, subjectMask: subjectMask, extent: extent)
        return PhotoSkinEnhancementProcessor.apply(
            to: image,
            skinMask: skinMask,
            whitening: whitening,
            smoothing: smoothing,
            profile: .app,
            warmth: warmth
        )
    }

    private static func applySkinWhiteBalance(
        to image: CIImage,
        sourceForMask: CIImage,
        subjectMask: CIImage?
    ) -> CIImage {
        guard let subjectMask else { return image }
        let extent = image.extent
        let skinMask = makeSkinMask(from: sourceForMask, subjectMask: subjectMask, extent: extent)
        guard let average = maskedAverageRGB(of: sourceForMask, mask: skinMask, extent: extent) else {
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
        extent: CGRect
    ) -> (r: Double, g: Double, b: Double, coverage: Double)? {
        let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])

        guard let weightedAverage = areaAverageRGBA(weighted, extent: extent),
              let maskAverage = areaAverageRGBA(mask, extent: extent),
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

    private static func areaAverageRGBA(_ image: CIImage, extent: CGRect) -> (r: Double, g: Double, b: Double, a: Double)? {
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
