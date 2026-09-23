import PhotoStyleShared
import AppKit
import CoreImage
import Vision

enum PhotoStyleAdjustmentMapper {
    private static let statisticsContext = PhotoImageRenderPrecision.makeContext()
    static func adjustment(
        from plan: PhotoStylePlan,
        style: PhotoStyle,
        baseAdjustment: StyleAdjustment,
        usesCustomPrompt: Bool = false
    ) -> StyleAdjustment {
        let plan = PhotoStylePlanPolicyResolver.resolve(plan, style: style, usesCustomPrompt: usesCustomPrompt)
        let directControls = usesCustomPrompt || plan.editorControls != nil
        let shadows = plan.toneZones.shadows
        let midtones = plan.toneZones.midtones
        let highlights = plan.toneZones.highlights
        let vignette = max(0, plan.postProcessing.vignette)
        let exposureBalance = directControls ? PhotoToneZoneBalance(
            common: 0, shadows: Double(shadows.exposure),
            midtones: Double(midtones.exposure), highlights: Double(highlights.exposure)
        ) : exposureBalance(
            shadows: shadows.exposure,
            midtones: midtones.exposure,
            highlights: highlights.exposure,
            style: style
        )
        let warmthBalance = directControls ? PhotoToneZoneBalance(
            common: 0, shadows: Double(shadows.warmth),
            midtones: Double(midtones.warmth), highlights: Double(highlights.warmth)
        ) : PhotoToneZoneBalancer.balance(
            shadows: Double(shadows.warmth),
            midtones: Double(midtones.warmth),
            highlights: Double(highlights.warmth),
            commonScale: style == .autoDetection ? 1.0 : 0.75,
            residualScale: 0.65,
            commonLimits: -60...60,
            residualLimits: -40...40
        )

        var adjustment = baseAdjustment
        adjustment.imageScoped = true
        adjustment.sourceToneZones = plan.toneZones
        adjustment.filmEffects = plan.filmEffects.clamped()
        // Archived v1–v3 plans describe physical paper exposure. Live v4 plans
        // and editor/MCP values all describe positive = brighter compensation.
        if plan.schemaVersion < 4, let stock = style.filmStock, stock.family != "reversal" {
            adjustment.filmEffects.printExposure = -adjustment.filmEffects.printExposure
        }
        adjustment.intensity = Double(plan.strength).clamped(to: 0...100)
        adjustment.highlightExposure = exposureBalance.highlights
        adjustment.highlightIntensity = Double(highlights.mapping)
        adjustment.highlightWarmth = warmthBalance.highlights
        adjustment.highlightGrain = Double(highlights.grain)
        adjustment.midtoneExposure = exposureBalance.midtones
        adjustment.midtoneIntensity = Double(midtones.mapping)
        adjustment.midtoneWarmth = warmthBalance.midtones
        adjustment.midtoneGrain = Double(midtones.grain)
        adjustment.shadowExposure = exposureBalance.shadows
        adjustment.shadowIntensity = Double(shadows.mapping)
        adjustment.shadowWarmth = warmthBalance.shadows
        adjustment.shadowGrain = Double(shadows.grain)
        adjustment.grain = Double(plan.postProcessing.grain)
        adjustment.exposure = exposureBalance.common
        adjustment.whiteBalanceWarmth = warmthBalance.common
        adjustment.whiteBalanceTint = 0
        adjustment.contrast = 0
        adjustment.brightness = 50
        adjustment.vignette = Double(vignette)
        adjustment.denoise = Double(max(0, plan.postProcessing.denoise))
        adjustment.devignette = Double(max(0, plan.postProcessing.devignette))
        adjustment.backgroundBlur = Double(max(0, plan.backgroundBlur)).clamped(to: 0...100)
        adjustment.skinWhitening = Double(max(0, plan.skinWhitening))
        adjustment.skinSmoothing = Double(max(0, plan.skinSmoothing))
        if let hdrToneCurve = plan.hdrToneCurve {
            adjustment.hdrToneCurve = hdrToneCurve
        } else if baseAdjustment.hdrToneCurve?.hasVisibleEffect == true {
            adjustment.hdrToneCurve = baseAdjustment.hdrToneCurve
        } else {
            adjustment.hdrToneCurve = PhotoHDRProcessor.curve(inferredFromAI: plan.toneZones)
        }
        if let editor = plan.editorControls {
            adjustment.exposure = editor.exposure.clamped(to: -100...100)
            adjustment.whiteBalanceWarmth = editor.whiteBalanceWarmth.clamped(to: -100...100)
            adjustment.whiteBalanceTint = editor.whiteBalanceTint.clamped(to: -100...100)
            adjustment.contrast = editor.contrast.clamped(to: -100...100)
            adjustment.brightness = editor.brightness.clamped(to: 0...100)
            adjustment.hdrAmount = editor.hdrAmount.clamped(to: 0...100)
            adjustment.cropAspectRatio = CropAspectRatio(rawValue: editor.cropAspectRatio) ?? baseAdjustment.cropAspectRatio
            adjustment.cropRotation = (editor.cropRotation ?? baseAdjustment.cropRotation).clamped(to: -45...45)
            adjustment.cropScale = editor.cropScale.clamped(to: 20...100)
            adjustment.cropWidth = editor.cropWidth.clamped(to: 20...100)
            adjustment.cropHeight = editor.cropHeight.clamped(to: 20...100)
            adjustment.cropHorizontalPosition = editor.cropHorizontalPosition.clamped(to: -100...100)
            adjustment.cropVerticalPosition = editor.cropVerticalPosition.clamped(to: -100...100)
            adjustment.frameEnabled = editor.frameEnabled
            adjustment.frameStyle = FrameStyle(rawValue: editor.frameStyle) ?? baseAdjustment.frameStyle
            adjustment.dateEnabled = editor.dateEnabled
            adjustment.dateStyle = DateStampStyle(rawValue: editor.dateStyle) ?? baseAdjustment.dateStyle
        }
        return adjustment
    }

    static func editorControls(from adjustment: StyleAdjustment) -> PhotoEditorControls {
        var controls = PhotoEditorControls()
        controls.exposure = adjustment.exposure
        controls.whiteBalanceWarmth = adjustment.whiteBalanceWarmth
        controls.whiteBalanceTint = adjustment.whiteBalanceTint
        controls.contrast = adjustment.contrast
        controls.brightness = adjustment.brightness
        controls.hdrAmount = adjustment.hdrAmount
        controls.cropAspectRatio = adjustment.cropAspectRatio.rawValue
        controls.cropRotation = adjustment.cropRotation
        controls.cropScale = adjustment.cropScale
        controls.cropWidth = adjustment.cropWidth
        controls.cropHeight = adjustment.cropHeight
        controls.cropHorizontalPosition = adjustment.cropHorizontalPosition
        controls.cropVerticalPosition = adjustment.cropVerticalPosition
        controls.frameEnabled = adjustment.frameEnabled
        controls.frameStyle = adjustment.frameStyle.rawValue
        controls.dateEnabled = adjustment.dateEnabled
        controls.dateStyle = adjustment.dateStyle.rawValue
        return controls
    }

    private static func exposureBalance(
        shadows: Int,
        midtones: Int,
        highlights: Int,
        style: PhotoStyle
    ) -> PhotoToneZoneBalance {
        if style == .autoDetection {
            return PhotoToneZoneBalancer.balance(
                shadows: Double(shadows),
                midtones: Double(midtones),
                highlights: Double(highlights),
                residualScale: 0.55,
                commonLimits: -60...60,
                residualLimits: -30...30
            )
        }

        return PhotoToneZoneBalancer.balance(
            shadows: Double(shadows),
            midtones: Double(midtones),
            highlights: Double(highlights),
            commonScale: 0.85,
            residualScale: 0.70,
            commonLimits: -45...12,
            residualLimits: -35...35
        )
    }

    static func mergeAutoDetectionAdjustment(_ llmAdjustment: StyleAdjustment, with imageAdjustment: StyleAdjustment) -> StyleAdjustment {
        var output = llmAdjustment
        // Compare in EV so the wider positive slider keeps the same correction
        // threshold and weighting as negative exposure.
        output.exposure = PhotoExposureScale.sliderValue(fromEV: chooseCorrection(
            PhotoExposureScale.ev(fromSlider: llmAdjustment.exposure),
            fallback: PhotoExposureScale.ev(fromSlider: imageAdjustment.exposure),
            smallThreshold: 0.12
        ))
        output.whiteBalanceWarmth = chooseCorrection(
            llmAdjustment.whiteBalanceWarmth,
            fallback: imageAdjustment.whiteBalanceWarmth,
            smallThreshold: 4
        )
        let zones = llmAdjustment.sourceToneZones
        let hasZoneTint = zones.map { $0.shadows.tint != 0 || $0.midtones.tint != 0 || $0.highlights.tint != 0 } ?? false
        let hasZoneContrast = zones.map { $0.shadows.contrast != 0 || $0.midtones.contrast != 0 || $0.highlights.contrast != 0 } ?? false
        // Zone corrections are rendered directly; statistics must not add a second correction.
        if !hasZoneTint {
            output.whiteBalanceTint = chooseCorrection(
                llmAdjustment.whiteBalanceTint,
                fallback: imageAdjustment.whiteBalanceTint,
                smallThreshold: 4
            )
        }
        if !hasZoneContrast {
            output.contrast = chooseCorrection(llmAdjustment.contrast, fallback: imageAdjustment.contrast, smallThreshold: 3)
        }
        output.brightness = 50
        return output
    }

    private static func chooseCorrection(_ value: Double, fallback: Double, smallThreshold: Double) -> Double {
        guard abs(fallback) >= smallThreshold else { return value.clamped(to: -100...100) }
        guard abs(value) >= smallThreshold else { return fallback.clamped(to: -100...100) }
        if (value > 0 && fallback > 0) || (value < 0 && fallback < 0) {
            return (value * 0.35 + fallback * 0.65).clamped(to: -100...100)
        }
        return fallback.clamped(to: -100...100)
    }

    static func imageBasedAutoCorrection(for image: PhotoImage, baseAdjustment: StyleAdjustment) -> StyleAdjustment? {
        guard let stats = AutoImageStats(image: image) else { return nil }

        var adjustment = baseAdjustment
        adjustment.exposure = stats.exposureSliderValue
        adjustment.whiteBalanceWarmth = stats.warmthCorrection
        adjustment.whiteBalanceTint = stats.tintCorrection
        adjustment.brightness = 50
        adjustment.contrast = stats.contrastSliderValue
        return adjustment
    }

    /// 統計與模型看到的照片一致，只提供判斷依據，不覆寫 AI 或使用者的數值。
    static func imageAnalysisSummary(for image: PhotoImage) -> String? {
        guard let stats = AutoImageStats(image: image) else { return nil }
        func number(_ value: Double) -> String {
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let faces = faceLuminances(in: image)
        let subjectSummary = faces.isEmpty
            ? "A conservative whole-image exposure estimate is \(number(PhotoExposureScale.ev(fromSlider: stats.exposureSliderValue))) EV before style-strength attenuation."
            : "Detected face-region median luminances: \(faces.map(number).joined(separator: ", ")). The whole-image histogram may be dominated by the background; judge subject exposure separately. Face brightness is evidence, not a fixed skin-tone target."
        return "Measured input linear-light luminance (0=black, 1=white): median=\(number(stats.medianLuminance)), mean=\(number(stats.meanLuminance)), p95=\(number(stats.highlightLuminance)). \(subjectSummary) These measurements are advisory: distinguish intentional low-key scenes and protect bright backgrounds. They are not requested slider values."
    }

    private static func faceLuminances(in image: PhotoImage) -> [Double] {
        guard let bitmap = image.resizedForWebPreview(maxPixel: 800).cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: bitmap, options: [:]).perform([request]) }
        catch { return [] }
        return (request.results ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .prefix(8).compactMap { face in
                // Vision 座標原點在左下；CGImage 裁切使用左上，略縮區域以減少頭髮與背景。
                let box = face.boundingBox.insetBy(dx: face.boundingBox.width * 0.15, dy: face.boundingBox.height * 0.15)
                let rect = CGRect(x: box.minX * Double(bitmap.width), y: (1 - box.maxY) * Double(bitmap.height),
                                  width: box.width * Double(bitmap.width), height: box.height * Double(bitmap.height))
                guard let crop = bitmap.cropping(to: rect.integral) else { return nil }
                return AutoImageStats(image: PhotoImage(cgImage: crop))?.medianLuminance
            }
    }

    private struct AutoImageStats {
        let medianLuminance: Double
        let meanLuminance: Double
        let highlightLuminance: Double
        let exposureSliderValue: Double
        let contrastSliderValue: Double
        let warmthCorrection: Double
        let tintCorrection: Double

        init?(image: PhotoImage) {
            let maxSide: CGFloat = 192
            let sourceSize = image.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

            let scale = min(1, maxSide / max(sourceSize.width, sourceSize.height))
            let width = max(1, Int((sourceSize.width * scale).rounded()))
            let height = max(1, Int((sourceSize.height * scale).rounded()))
            let outputSize = CGSize(width: width, height: height)

            let normalized = image.resized(to: outputSize)
            guard let cgImage = normalized.cgImage else { return nil }

            var rgba = [Float](repeating: 0, count: width * height * 4)
            PhotoStyleAdjustmentMapper.statisticsContext.render(
                CIImage(cgImage: cgImage), toBitmap: &rgba,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            )

            var lumas: [Double] = []
            lumas.reserveCapacity(width * height)
            var redSum = 0.0
            var greenSum = 0.0
            var blueSum = 0.0
            var neutralCount = 0.0

            stride(from: 0, to: rgba.count, by: 4).forEach { index in
                let alpha = Double(rgba[index + 3])
                guard alpha.isFinite, alpha > 24.0 / 255 else { return }
                let red = max(0, Double(rgba[index]) / alpha)
                let green = max(0, Double(rgba[index + 1]) / alpha)
                let blue = max(0, Double(rgba[index + 2]) / alpha)
                guard red.isFinite, green.isFinite, blue.isFinite else { return }
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                lumas.append(luma)

                let maxChannel = max(red, max(green, blue))
                let minChannel = min(red, min(green, blue))
                if luma > 0.06, luma < 0.88, maxChannel - minChannel < 0.16 {
                    redSum += red
                    greenSum += green
                    blueSum += blue
                    neutralCount += 1
                }
            }

            guard lumas.count > 32 else { return nil }
            lumas.sort()

            let p10 = Self.percentile(0.10, values: lumas)
            let p50 = Self.percentile(0.50, values: lumas)
            let p90 = Self.percentile(0.90, values: lumas)
            let p95 = Self.percentile(0.95, values: lumas)
            let mean = lumas.reduce(0, +) / Double(lumas.count)
            medianLuminance = p50
            meanLuminance = mean
            highlightLuminance = p95

            let exposure = PhotoAutoExposureCalculator.sliderValue(
                p50: p50,
                mean: mean,
                p95: p95
            )

            let tonalSpan = p90 - p10
            var contrastOffset = 0.0
            if tonalSpan < 0.34 {
                contrastOffset = (0.34 - tonalSpan) * 95
            } else if tonalSpan > 0.74 {
                contrastOffset = (0.74 - tonalSpan) * 65
            }
            let contrast = (abs(contrastOffset) < 3 ? 0 : contrastOffset).clamped(to: -16...24)

            var warmth = 0.0
            var tint = 0.0
            if neutralCount > 16 {
                let redAverage = redSum / neutralCount
                let greenAverage = greenSum / neutralCount
                let blueAverage = blueSum / neutralCount
                warmth = ((blueAverage - redAverage) * 180).clamped(to: -42...42)
                tint = ((greenAverage - (redAverage + blueAverage) * 0.5) * 170).clamped(to: -36...36)
                if abs(warmth) < 4 { warmth = 0 }
                if abs(tint) < 4 { tint = 0 }
            }

            exposureSliderValue = exposure.clamped(to: -100...100)
            contrastSliderValue = contrast
            warmthCorrection = warmth
            tintCorrection = tint
        }

        private static func percentile(_ percentile: Double, values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let position = percentile.clamped(to: 0...1) * Double(values.count - 1)
            let lower = Int(floor(position))
            let upper = Int(ceil(position))
            guard lower != upper else { return values[lower] }
            let fraction = position - Double(lower)
            return values[lower] * (1 - fraction) + values[upper] * fraction
        }
    }
}
