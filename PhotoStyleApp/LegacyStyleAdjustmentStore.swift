import PhotoStyleShared
import Foundation
import Combine

// 僅供尚待遷移的舊 Swift 桌面使用；不編入 Go 宿主的原生影像引擎。
// 混合版本的配方狀態與保存由 desktop/internal/application、storage 管理。
final class LegacyStyleAdjustmentStore: ObservableObject {
    @Published private(set) var adjustments: [PhotoStyle: StyleAdjustment]
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let defaultsKey = "styleAdjustments.v1"
    private let toneMappingMigrationKey = "styleAdjustments.toneMappingV2"
    private let processingSemanticsMigrationKey = "styleAdjustments.processingSemanticsV3"
    private let styleProfilesMigrationKey = "styleAdjustments.styleProfiles20260713"
    private let stylePlanPolicyMigrationKey = "styleAdjustments.stylePlanPolicy20260714"
    private let hamadaReferenceMigrationKey = "styleAdjustments.hamadaReference20260714"
    private let kawauchiReferenceMigrationKey = "styleAdjustments.kawauchiReference20260714"
    private let hdrAmountDefaultMigrationKey = "styleAdjustments.hdrAmountDefault20260718"

    private struct StoredAdjustments: Decodable {
        var values: [PhotoStyle: StyleAdjustment] = [:]
        var hasDamagedRecords = false

        private struct StyleKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ style: PhotoStyle) { stringValue = style.rawValue }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: StyleKey.self)
            for style in PhotoStyle.allCases {
                let key = StyleKey(style)
                guard container.contains(key) else { continue }
                do {
                    values[style] = try container.decode(StyleAdjustment.self, forKey: key)
                } catch {
                    // Decode each record separately, including numbers too large for Double.
                    hasDamagedRecords = true
                }
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var needsPersistenceRepair = false
        var restored: [PhotoStyle: StyleAdjustment] = [:]
        if let data = defaults.data(forKey: defaultsKey) {
            if let records = try? JSONDecoder().decode(StoredAdjustments.self, from: data) {
                needsPersistenceRepair = records.hasDamagedRecords
                for (style, decoded) in records.values {
                    let normalized = decoded.clamped()
                    restored[style] = normalized
                    needsPersistenceRepair = needsPersistenceRepair || normalized != decoded
                }
            } else {
                needsPersistenceRepair = true
            }
        }
        adjustments = Dictionary(uniqueKeysWithValues: PhotoStyle.allCases.map { style in
            (style, restored[style] ?? StyleAdjustment.default(for: style))
        })

        if !defaults.bool(forKey: toneMappingMigrationKey) {
            resetImageScopedCorrections()
            save()
            defaults.set(true, forKey: toneMappingMigrationKey)
        }
        if !defaults.bool(forKey: processingSemanticsMigrationKey) {
            resetAllProcessingAdjustments()
            save()
            defaults.set(true, forKey: processingSemanticsMigrationKey)
        }
        if !defaults.bool(forKey: styleProfilesMigrationKey) {
            resetAllProcessingAdjustments()
            save()
            defaults.set(true, forKey: styleProfilesMigrationKey)
        }
        if !defaults.bool(forKey: stylePlanPolicyMigrationKey) {
            resetAllProcessingAdjustments()
            save()
            defaults.set(true, forKey: stylePlanPolicyMigrationKey)
        }
        if !defaults.bool(forKey: hamadaReferenceMigrationKey) {
            resetProcessingAdjustments(for: [.japaneseColor1, .japaneseColor2])
            defaults.set(true, forKey: hamadaReferenceMigrationKey)
        }
        if !defaults.bool(forKey: kawauchiReferenceMigrationKey) {
            resetProcessingAdjustments(for: [.japaneseColor2])
            defaults.set(true, forKey: kawauchiReferenceMigrationKey)
        }
        if !defaults.bool(forKey: hdrAmountDefaultMigrationKey) {
            adjustments = Dictionary(uniqueKeysWithValues: adjustments.map { style, adjustment in
                var output = adjustment
                if output.hdrAmount >= 99.5 {
                    output.hdrAmount = 25
                }
                return (style, output)
            })
            save()
            defaults.set(true, forKey: hdrAmountDefaultMigrationKey)
        }
        for style in PhotoStyle.allCases where style.cameraProfile != nil {
            if adjustments[style]?.filmEffects.scannerProfile != .off {
                adjustments[style]?.filmEffects.scannerProfile = .off
                needsPersistenceRepair = true
            }
        }
        if needsPersistenceRepair { save() }
    }

    func adjustment(for style: PhotoStyle) -> StyleAdjustment {
        var result = adjustments[style] ?? StyleAdjustment.default(for: style)
        if style.cameraProfile != nil { result.filmEffects.scannerProfile = .off }
        if (style.filmStock != nil || style == .original) && result.filmEffects.scannerProfile == .off {
            result.filmEffects.scannerProfile = .neutral
        }
        return result
    }

    func restorePhotoAdjustments(_ values: [String: StyleAdjustment]) {
        adjustments = Dictionary(uniqueKeysWithValues: PhotoStyle.allCases.map { style in
            (style, values[style.rawValue]?.clamped() ?? StyleAdjustment.default(for: style))
        })
        save()
    }

    func startNewPhoto() {
        adjustments = Dictionary(uniqueKeysWithValues: PhotoStyle.allCases.map { style in
            let previous = adjustment(for: style)
            var next = StyleAdjustment.default(for: style)
            next.frameEnabled = previous.frameEnabled
            next.frameStyle = previous.frameStyle
            next.dateEnabled = previous.dateEnabled
            next.dateStyle = previous.dateStyle
            return (style, next)
        })
        save()
    }

    func setAdjustment(_ adjustment: StyleAdjustment, for style: PhotoStyle) {
        adjustments[style] = adjustment.clamped()
        save()
    }

    // Applying a look without AI starts from that look's own processing preset.
    // Crop belongs to the photo; decorations remain the selected look's preference.
    // This is deliberately explicit so observing state never overwrites a manual edit.
    static func defaultAdjustment(for style: PhotoStyle, previous: StyleAdjustment, preservingCropFrom crop: StyleAdjustment?) -> StyleAdjustment {
        var next = StyleAdjustment.default(for: style)
        next.frameEnabled = previous.frameEnabled
        next.frameStyle = previous.frameStyle
        next.dateEnabled = previous.dateEnabled
        next.dateStyle = previous.dateStyle
        next.colorCalibration = style == .original ? nil : previous.colorCalibration
        if let crop {
            next.cropAspectRatio = crop.cropAspectRatio
            next.cropRotation = crop.cropRotation
            next.cropScale = crop.cropScale
            next.cropWidth = crop.cropWidth
            next.cropHeight = crop.cropHeight
            next.cropHorizontalPosition = crop.cropHorizontalPosition
            next.cropVerticalPosition = crop.cropVerticalPosition
            next.imageScoped = crop.cropAspectRatio != .original
                || crop.cropRotation != 0 || crop.cropScale != 100 || crop.cropWidth != 100 || crop.cropHeight != 100
                || crop.cropHorizontalPosition != 0 || crop.cropVerticalPosition != 0
        }
        return next
    }

    func resetImageScopedCorrections() {
        adjustments = Dictionary(uniqueKeysWithValues: adjustments.map { style, adjustment in
            if adjustment.imageScoped {
                return (style, defaultAdjustmentPreservingDecorations(for: style, from: adjustment))
            }
            var next = adjustment
            next.imageScoped = false
            next.cropAspectRatio = .original
            next.cropRotation = 0
            next.cropScale = 100
            next.cropWidth = 100
            next.cropHeight = 100
            next.cropHorizontalPosition = 0
            next.cropVerticalPosition = 0
            next.exposure = 0
            next.vibrance = 0
            next.saturation = 0
            next.whiteBalanceWarmth = 0
            next.whiteBalanceTint = 0
            next.highlightExposure = 0
            next.highlightWarmth = 0
            next.midtoneExposure = 0
            next.midtoneWarmth = 0
            next.shadowExposure = 0
            next.shadowWarmth = 0
            if style == .autoDetection {
                next.brightness = 50
                next.contrast = 0
            }
            return (style, next)
        })
        save()
    }

    private func resetAllProcessingAdjustments() {
        adjustments = Dictionary(uniqueKeysWithValues: adjustments.map { style, adjustment in
            (style, defaultAdjustmentPreservingDecorations(for: style, from: adjustment))
        })
    }

    private func resetProcessingAdjustments(for styles: [PhotoStyle]) {
        for style in styles {
            let current = adjustments[style] ?? StyleAdjustment.default(for: style)
            adjustments[style] = defaultAdjustmentPreservingDecorations(for: style, from: current)
        }
        save()
    }

    private func defaultAdjustmentPreservingDecorations(
        for style: PhotoStyle,
        from adjustment: StyleAdjustment
    ) -> StyleAdjustment {
        var output = StyleAdjustment.default(for: style)
        output.frameEnabled = adjustment.frameEnabled
        output.frameStyle = adjustment.frameStyle
        output.dateEnabled = adjustment.dateEnabled
        output.dateStyle = adjustment.dateStyle
        output.hdrAmount = adjustment.hdrAmount
        return output
    }

    private func save() {
        // Normalize legacy recipes and AI/MCP edits at the persistence boundary.
        for style in PhotoStyle.allCases where style.cameraProfile != nil {
            adjustments[style]?.filmEffects.scannerProfile = .off
        }
        for style in PhotoStyle.allCases where style.filmStock != nil || style == .original {
            if adjustments[style]?.filmEffects.scannerProfile == .off {
                adjustments[style]?.filmEffects.scannerProfile = .neutral
            }
        }
        let encoded = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: defaultsKey)
        onChange?()
    }
}

// 僅供舊 Swift 桌面使用；Go 宿主的投影統一由 internal/recipes 提供。
enum PhotoAdjustmentWebPayload {
    static func adjustmentPayload(_ adjustment: StyleAdjustment) -> [String: Any] {
        [
            "colorCalibrationName": adjustment.colorCalibration?.name ?? "",
            "colorCalibrationStage": adjustment.colorCalibration?.stage.rawValue ?? "",
            "intensity": adjustment.intensity,
            "exposure": adjustment.exposure,
            "vibrance": adjustment.vibrance,
            "saturation": adjustment.saturation,
            "whiteBalanceWarmth": adjustment.whiteBalanceWarmth,
            "whiteBalanceTint": adjustment.whiteBalanceTint,
            "brightness": adjustment.brightness,
            "contrast": adjustment.contrast,
            "grain": adjustment.grain,
            "filmColorModel": adjustment.filmEffects.colorModel.rawValue,
            "printIlluminant": adjustment.filmEffects.printIlluminant.rawValue,
            "viewIlluminant": adjustment.filmEffects.viewIlluminant.rawValue,
            "scannerSource": adjustment.filmEffects.scannerSource.rawValue,
            "scannerProfile": adjustment.filmEffects.scannerProfile.rawValue,
            "scannerIlluminant": adjustment.filmEffects.scannerIlluminant.rawValue,
            "scanExposure": adjustment.filmEffects.scanExposure,
            "scanContrast": adjustment.filmEffects.scanContrast,
            "scanSaturation": adjustment.filmEffects.scanSaturation,
            "scanDensityCorrection": adjustment.filmEffects.scanDensityCorrection,
            "scanFlare": adjustment.filmEffects.scanFlare,
            "scanMidtoneWarmth": adjustment.filmEffects.scanMidtoneWarmth,
            "scanHighlightWarmth": adjustment.filmEffects.scanHighlightWarmth,
            "printExposure": adjustment.filmEffects.printExposure,
            "printExposureHighlights": adjustment.filmEffects.printExposureHighlights ?? adjustment.filmEffects.printExposure,
            "printExposureMidtones": adjustment.filmEffects.printExposureMidtones ?? adjustment.filmEffects.printExposure,
            "printExposureShadows": adjustment.filmEffects.printExposureShadows ?? adjustment.filmEffects.printExposure,

            "printContrast": adjustment.filmEffects.printContrast,
            "developmentAmount": adjustment.filmEffects.developmentAmount,
            "developmentTime": adjustment.filmEffects.developmentTime,
            "developmentDiffusion": adjustment.filmEffects.developmentDiffusion,
            "paperProfile": adjustment.filmEffects.paperProfile.rawValue,
            "layerResponse": adjustment.filmEffects.layerResponse,
            "couplerAmount": adjustment.filmEffects.couplerAmount,
            "couplerRadius": adjustment.filmEffects.couplerRadius,
            "filmWidthMM": adjustment.filmEffects.filmWidthMM,
            "grainDistribution": adjustment.filmEffects.grainDistribution,
            "emulsionMTF": adjustment.filmEffects.emulsionMTF,
            "paperScatter": adjustment.filmEffects.paperScatter,
            "paperWhite": adjustment.filmEffects.paperWhite,
            "paperDensityOffset": adjustment.filmEffects.paperDensityOffset,
            "reciprocityAmount": adjustment.filmEffects.reciprocityAmount,
            "exposureSeconds": adjustment.filmEffects.exposureSeconds,
            "halationBase": adjustment.filmEffects.halationBase,
            "silverRetention": adjustment.filmEffects.silverRetention,
            "developerTemperature": adjustment.filmEffects.developerTemperature,
            "developerActivity": adjustment.filmEffects.developerActivity,
            "developerContrast": adjustment.filmEffects.developerChemistry[.developerContrast],
            "developerSpeed": adjustment.filmEffects.developerChemistry[.developerSpeed],
            "developerCompensation": adjustment.filmEffects.developerChemistry[.developerCompensation],
            "developerGrain": adjustment.filmEffects.developerChemistry[.developerGrain],
            "developerAcutance": adjustment.filmEffects.developerChemistry[.developerAcutance],
            "developerRed": adjustment.filmEffects.developerChemistry[.developerRed],
            "developerGreen": adjustment.filmEffects.developerChemistry[.developerGreen],
            "developerBlue": adjustment.filmEffects.developerChemistry[.developerBlue],
            "developmentAgitation": adjustment.filmEffects.developmentAgitation,
            "grainMode": adjustment.filmEffects.grainMode.rawValue,
            "grainSize": adjustment.filmEffects.grainSize,
            "grainClumping": adjustment.filmEffects.grainClumping,
            "grainChroma": adjustment.filmEffects.grainChroma,
            "bloomAmount": adjustment.filmEffects.bloomAmount,
            "bloomRadius": adjustment.filmEffects.bloomRadius,
            "bloomThreshold": adjustment.filmEffects.bloomThreshold,
            "halationAmount": adjustment.filmEffects.halationAmount,
            "halationRadius": adjustment.filmEffects.halationRadius,
            "halationThreshold": adjustment.filmEffects.halationThreshold,
            "monochromeFilter": adjustment.filmEffects.monochromeFilter.rawValue,
            "monochromeFilterStrength": adjustment.filmEffects.monochromeFilterStrength,
            "vignette": adjustment.vignette,
            "denoise": adjustment.denoise,
            "devignette": adjustment.devignette,
            "backgroundBlur": adjustment.backgroundBlur,
            "skinWarmth": adjustment.skinWarmth,
            "skinWhitening": adjustment.skinWhitening,
            "skinSmoothing": adjustment.skinSmoothing,
            "hdrAmount": adjustment.hdrAmount,
            "hdrToneCurve": adjustment.hdrToneCurve.map { curve in
                ["black": curve.black, "shadows": curve.shadows, "midtones": curve.midtones,
                 "highlights": curve.highlights, "white": curve.white, "detail": curve.detail]
            } ?? NSNull(),
            "cropAspectRatio": adjustment.cropAspectRatio.rawValue,
            "cropRotation": adjustment.cropRotation,
            "cropScale": adjustment.cropScale,
            "cropWidth": adjustment.cropWidth,
            "cropHeight": adjustment.cropHeight,
            "cropHorizontalPosition": adjustment.cropHorizontalPosition,
            "cropVerticalPosition": adjustment.cropVerticalPosition,
            "highlightExposure": adjustment.highlightExposure,
            "highlightIntensity": adjustment.highlightIntensity,
            "highlightWarmth": adjustment.highlightWarmth,
            "highlightGrain": adjustment.highlightGrain,
            "midtoneExposure": adjustment.midtoneExposure,
            "midtoneIntensity": adjustment.midtoneIntensity,
            "midtoneWarmth": adjustment.midtoneWarmth,
            "midtoneGrain": adjustment.midtoneGrain,
            "shadowExposure": adjustment.shadowExposure,
            "shadowIntensity": adjustment.shadowIntensity,
            "shadowWarmth": adjustment.shadowWarmth,
            "shadowGrain": adjustment.shadowGrain,
            "sourceToneZones": adjustment.sourceToneZones.map(toneZonesPayload(_:)) ?? NSNull(),
            "frameEnabled": adjustment.frameEnabled,
            "frameStyle": adjustment.frameStyle.rawValue,
            "dateEnabled": adjustment.dateEnabled,
            "dateStyle": adjustment.dateStyle.rawValue
        ]
    }

    static func toneZonesPayload(_ toneZones: PhotoStylePlan.ToneZones) -> [String: Any] {
        [
            "shadows": toneAdjustmentPayload(toneZones.shadows),
            "midtones": toneAdjustmentPayload(toneZones.midtones),
            "highlights": toneAdjustmentPayload(toneZones.highlights)
        ]
    }

    static func toneAdjustmentPayload(_ adjustment: PhotoStylePlan.ToneAdjustment) -> [String: Any] {
        [
            "baseTone": adjustment.baseTone,
            "contrast": adjustment.contrast,
            "softness": adjustment.softness,
            "highlights": adjustment.highlights,
            "shadows": adjustment.shadows,
            "fade": adjustment.fade,
            "tint": adjustment.tint
        ]
    }

}
