import PhotoStyleShared
import SwiftUI

enum PhotoStyle: String, CaseIterable, Identifiable {
    case original
    case autoDetection
    case japaneseColor1
    case japaneseColor2
    case japaneseBWStrong
    case japaneseBWStandard
    case japaneseBWSoft
    case fujiProvia
    case fujiClassicChrome
    case fujiClassicNeg

    case filmPortra160
    case filmPortra400
    case filmPortra800
    case filmEktar100
    case filmVision50D
    case filmVision250D
    case filmVision200T
    case filmVision500T
    case filmEktachrome100
    case filmVelvia50
    case filmProvia100F
    case filmHP5
    case filmFP4
    case filmOrtho80
    case filmSFX200
    case filmInfrared400
    case filmBleachBypass
    case filmCrossProcess
    case filmGold200
    case filmCineStill800T
    case filmPolaroidSX70
    case filmDelta3200
    case gr3Negative = "gr3-negative"
    case gr3HardMono = "gr3-hardmono"
    case gr4Yellow = "gr4-yellow"
    case gr4Green = "gr4-green"

    case filmLomoPurple

    /// 精簡收藏入口；舊識別碼與配方保留，避免改變已儲存照片及自訂底片。
    var mergedInto: PhotoStyle? {
        switch self {
        case .filmPortra160, .filmPortra800: return .filmPortra400
        case .filmVision250D: return .filmVision50D
        case .filmVision200T: return .filmVision500T
        case .filmFP4: return .filmHP5
        default: return nil
        }
    }

    static var catalogCases: [PhotoStyle] { allCases.filter { $0.mergedInto == nil } }

    var cameraProfile: PhotoCameraProfile? { PhotoCameraProfile.profile(id: rawValue) }
    var isLibraryLook: Bool { filmStock != nil || cameraProfile != nil }
    var libraryFamily: String { cameraProfile != nil ? "camera" : (filmStock?.family ?? "") }
    var libraryFamilyTitle: String { cameraProfile != nil ? "模擬相機" : (filmStock?.familyTitle ?? "") }
    var libraryAlgorithm: String { cameraProfile != nil ? "以 Oklab 明度曲線、色相分離、陰影與亮部色調模擬相機風格；獨立近似，並非原廠 LUT。" : (filmStock?.algorithmDescription ?? "") }

    var filmStock: PhotoFilmStock? { PhotoFilmStock(rawValue: rawValue) }

    var id: String { rawValue }

    var isMonochrome: Bool {
        if let camera = cameraProfile { return camera.isMonochrome }
        if let stock = filmStock { return stock.isMonochrome }
        switch self {
        case .japaneseBWStrong, .japaneseBWStandard, .japaneseBWSoft:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .original:
            "原片"
        case .autoDetection:
            "自然色彩"
        case .japaneseColor1:
            "日式風格一"
        case .japaneseColor2:
            "日式風格二"
        case .japaneseBWStrong:
            "日式黑白強烈"
        case .japaneseBWStandard:
            "日式標準黑白"
        case .japaneseBWSoft:
            "日式黑白淡雅"
        case .fujiProvia:
            "底片 Provia"
        case .fujiClassicChrome:
            "底片 Classic Chrome"
        case .fujiClassicNeg:
            "底片 Classic Neg."
        default:
            cameraProfile?.title ?? filmStock?.title ?? rawValue
        }
    }

    var subtitle: String {
        switch self {
        case .original:
            "保留原始曝光與色調，不套用底片效果"
        case .autoDetection:
            "曝光、白平衡自然修正"
        case .japaneseColor1:
            "青藍清透、柔亮空氣感"
        case .japaneseColor2:
            "柔霧高光、淡青暖粉"
        case .japaneseBWStrong:
            "高反差、深黑街拍感"
        case .japaneseBWStandard:
            "厚實中調、顆粒稍重"
        case .japaneseBWSoft:
            "細膩灰階、柔和留白"
        case .fujiProvia:
            "中性乾淨、自然飽和"
        case .fujiClassicChrome:
            "低飽和、冷靜紀實"
        case .fujiClassicNeg:
            "青綠陰影、柔和負片感"
        default:
            cameraProfile?.subtitle ?? filmStock?.subtitle ?? ""
        }
    }

    var gradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .autoDetection:
            colors = [.blue, .white, .orange]
        case .japaneseColor1:
            colors = [
                Color(red: 0.45, green: 0.57, blue: 0.61),
                Color(red: 0.86, green: 0.88, blue: 0.87),
                Color(red: 0.92, green: 0.84, blue: 0.70)
            ]
        case .japaneseColor2:
            colors = [.pink, .white, .cyan]
        case .japaneseBWStrong:
            colors = [.black, .gray, .white]
        case .japaneseBWStandard:
            colors = [
                Color(red: 0.13, green: 0.13, blue: 0.12),
                Color(red: 0.48, green: 0.47, blue: 0.43),
                Color(red: 0.86, green: 0.84, blue: 0.78)
            ]
        case .japaneseBWSoft:
            colors = [.gray, .secondary, .white]
        case .fujiProvia:
            colors = [.green, .blue, .cyan]
        case .fujiClassicChrome:
            colors = [.blue, .gray, .orange]
        case .fujiClassicNeg:
            colors = [
                Color(red: 0.20, green: 0.34, blue: 0.35),
                Color(red: 0.67, green: 0.67, blue: 0.57),
                Color(red: 0.76, green: 0.33, blue: 0.24)
            ]
        default:
            colors = [.brown, .orange, .yellow]
        }

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum FrameStyle: String, CaseIterable, Codable, Identifiable {
    case whitePaperThin
    case whitePaperWide
    case whitePaperPolaroid
    case blackLine
    case filmStrip
    case cleanInset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whitePaperThin:
            "白色相紙(細)"
        case .whitePaperWide:
            "白色相紙(寬)"
        case .whitePaperPolaroid:
            "白色相紙(拍立得)"
        case .blackLine:
            "黑色細框"
        case .filmStrip:
            "復古底片"
        case .cleanInset:
            "留白內框"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = FrameStyle(rawValue: value == "whitePaper" ? "whitePaperThin" : value) ?? .whitePaperThin
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DateStampStyle: String, CaseIterable, Codable, Identifiable {
    case numeric
    case slash
    case compact
    case japanese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numeric:
            "YYYY.MM.DD"
        case .slash:
            "YY/MM/DD"
        case .compact:
            "YYYYMMDD"
        case .japanese:
            "YYYY年M月D日"
        }
    }

    var dateFormat: String {
        switch self {
        case .numeric:
            "yyyy.MM.dd"
        case .slash:
            "yy/MM/dd"
        case .compact:
            "yyyyMMdd"
        case .japanese:
            "yyyy年M月d日"
        }
    }
}

enum CropAspectRatio: String, CaseIterable, Codable, Identifiable {
    case original
    case source
    case free
    case threeTwo
    case oneOne
    case fourThree
    case sixteenNine

    var id: String { rawValue }

    func title(for imageSize: CGSize?) -> String {
        guard self != .original else { return "關閉" }
        let isPortrait = imageSize.map { $0.height > $0.width } ?? false
        switch self {
        case .original:
            return "關閉"
        case .source:
            return "原始比例"
        case .free:
            return "自由裁切"
        case .threeTwo:
            return isPortrait ? "2:3" : "3:2"
        case .oneOne:
            return "1:1"
        case .fourThree:
            return isPortrait ? "3:4" : "4:3"
        case .sixteenNine:
            return isPortrait ? "9:16" : "16:9"
        }
    }

    func targetAspectRatio(for imageSize: CGSize) -> CGFloat? {
        guard self != .original, self != .free else { return nil }
        let isPortrait = imageSize.height > imageSize.width
        switch self {
        case .original:
            return nil
        case .source:
            return imageSize.width / max(imageSize.height, 1)
        case .free:
            return nil
        case .threeTwo:
            return isPortrait ? 2.0 / 3.0 : 3.0 / 2.0
        case .oneOne:
            return 1
        case .fourThree:
            return isPortrait ? 3.0 / 4.0 : 4.0 / 3.0
        case .sixteenNine:
            return isPortrait ? 9.0 / 16.0 : 16.0 / 9.0
        }
    }
}

struct StyleAdjustment: Codable, Equatable {
    var imageScoped: Bool
    var sourceToneZones: PhotoStylePlan.ToneZones?
    var colorCalibration: PhotoColorCalibration?
    var filmEffects: PhotoFilmEffects
    var intensity: Double
    var exposure: Double
    var whiteBalanceWarmth: Double
    var whiteBalanceTint: Double
    var brightness: Double
    var contrast: Double
    var grain: Double
    var vignette: Double
    var denoise: Double
    var devignette: Double
    var backgroundBlur: Double
    var skinWarmth: Double
    var skinWhitening: Double
    var skinSmoothing: Double
    var hdrAmount: Double
    var hdrToneCurve: PhotoStylePlan.HDRToneCurve?
    var cropAspectRatio: CropAspectRatio
    var cropRotation: Double
    var cropScale: Double
    var cropWidth: Double
    var cropHeight: Double
    var cropHorizontalPosition: Double
    var cropVerticalPosition: Double
    var highlightExposure: Double
    var highlightIntensity: Double
    var highlightWarmth: Double
    var highlightGrain: Double
    var midtoneExposure: Double
    var midtoneIntensity: Double
    var midtoneWarmth: Double
    var midtoneGrain: Double
    var shadowExposure: Double
    var shadowIntensity: Double
    var shadowWarmth: Double
    var shadowGrain: Double
    var frameEnabled: Bool
    var frameStyle: FrameStyle
    var dateEnabled: Bool
    var dateStyle: DateStampStyle

    var requiresSubjectMask: Bool {
        backgroundBlur > 0.001 || abs(skinWarmth) > 0.001 || skinWhitening > 0.001 || skinSmoothing > 0.001
    }

    var needsHDRToneCurveComputation: Bool {
        hdrAmount > 0.001 && hdrToneCurve == nil
    }

    func cropRect(in extent: CGRect, verticalAxisInverted: Bool = false) -> CGRect {
        guard cropAspectRatio != .original else { return extent }
        let isFreeCrop = cropAspectRatio == .free
        let verticalPosition = cropVerticalPosition / 100 * (verticalAxisInverted ? -1 : 1)
        return PhotoCropCalculator.positionedCropRect(
            in: extent,
            targetAspectRatio: cropAspectRatio.targetAspectRatio(for: extent.size),
            widthScale: (isFreeCrop ? cropWidth : cropScale) / 100,
            heightScale: (isFreeCrop ? cropHeight : cropScale) / 100,
            horizontalPosition: cropHorizontalPosition / 100,
            verticalPosition: verticalPosition
        )
    }

    @discardableResult
    mutating func resolveHDRToneCurveFromAIAnalysisIfNeeded() -> Bool {
        guard needsHDRToneCurveComputation,
              let sourceToneZones else {
            return false
        }
        hdrToneCurve = PhotoHDRProcessor.curve(inferredFromAI: sourceToneZones)
        return true
    }

    enum CodingKeys: String, CodingKey {
        case colorCalibration
        case schemaVersion
        case imageScoped
        case sourceToneZones
        case filmEffects
        case intensity
        case exposure
        case whiteBalanceWarmth
        case whiteBalanceTint
        case brightness
        case contrast
        case grain
        case vignette
        case denoise
        case devignette
        case backgroundBlur
        case skinWarmth
        case skinWhitening
        case skinSmoothing
        case hdrAmount
        case hdrEnabled
        case hdrToneCurve
        case cropAspectRatio
        case cropRotation
        case cropScale
        case cropWidth
        case cropHeight
        case cropHorizontalPosition
        case cropVerticalPosition
        case highlightExposure
        case highlightIntensity
        case highlightWarmth
        case highlightGrain
        case midtoneExposure
        case midtoneIntensity
        case midtoneWarmth
        case midtoneGrain
        case shadowExposure
        case shadowIntensity
        case shadowWarmth
        case shadowGrain
        case frameEnabled
        case frameStyle
        case dateEnabled
        case dateStyle
    }

    init(
        imageScoped: Bool,
        sourceToneZones: PhotoStylePlan.ToneZones?,
        intensity: Double,
        exposure: Double,
        whiteBalanceWarmth: Double,
        whiteBalanceTint: Double,
        brightness: Double,
        contrast: Double,
        grain: Double,
        vignette: Double,
        denoise: Double,
        devignette: Double,
        backgroundBlur: Double,
        skinWarmth: Double = 0,
        skinWhitening: Double,
        skinSmoothing: Double,
        hdrAmount: Double,
        hdrToneCurve: PhotoStylePlan.HDRToneCurve?,
        cropAspectRatio: CropAspectRatio,
        cropRotation: Double = 0,
        cropScale: Double,
        cropWidth: Double,
        cropHeight: Double,
        cropHorizontalPosition: Double,
        cropVerticalPosition: Double,
        highlightExposure: Double,
        highlightIntensity: Double,
        highlightWarmth: Double,
        highlightGrain: Double,
        midtoneExposure: Double,
        midtoneIntensity: Double,
        midtoneWarmth: Double,
        midtoneGrain: Double,
        shadowExposure: Double,
        shadowIntensity: Double,
        shadowWarmth: Double,
        shadowGrain: Double,
        frameEnabled: Bool,
        frameStyle: FrameStyle,
        dateEnabled: Bool,
        dateStyle: DateStampStyle,
        filmEffects: PhotoFilmEffects = .neutral,
        colorCalibration: PhotoColorCalibration? = nil
    ) {
        self.colorCalibration = colorCalibration
        self.imageScoped = imageScoped
        self.sourceToneZones = sourceToneZones
        self.intensity = intensity
        self.exposure = exposure
        self.whiteBalanceWarmth = whiteBalanceWarmth
        self.whiteBalanceTint = whiteBalanceTint
        self.brightness = brightness
        self.contrast = contrast
        self.grain = grain
        self.vignette = vignette
        self.denoise = denoise
        self.devignette = devignette
        self.backgroundBlur = backgroundBlur
        self.skinWarmth = skinWarmth
        self.skinWhitening = skinWhitening
        self.skinSmoothing = skinSmoothing
        self.hdrAmount = hdrAmount
        self.hdrToneCurve = hdrToneCurve
        self.cropAspectRatio = cropAspectRatio
        self.cropRotation = cropRotation
        self.cropScale = cropScale
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.cropHorizontalPosition = cropHorizontalPosition
        self.cropVerticalPosition = cropVerticalPosition
        self.highlightExposure = highlightExposure
        self.highlightIntensity = highlightIntensity
        self.highlightWarmth = highlightWarmth
        self.highlightGrain = highlightGrain
        self.midtoneExposure = midtoneExposure
        self.midtoneIntensity = midtoneIntensity
        self.midtoneWarmth = midtoneWarmth
        self.midtoneGrain = midtoneGrain
        self.shadowExposure = shadowExposure
        self.shadowIntensity = shadowIntensity
        self.shadowWarmth = shadowWarmth
        self.shadowGrain = shadowGrain
        self.frameEnabled = frameEnabled
        self.frameStyle = frameStyle
        self.dateEnabled = dateEnabled
        self.dateStyle = dateStyle
        self.filmEffects = filmEffects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        imageScoped = try container.decodeIfPresent(Bool.self, forKey: .imageScoped) ?? false
        sourceToneZones = try container.decodeIfPresent(PhotoStylePlan.ToneZones.self, forKey: .sourceToneZones)
        colorCalibration = try container.decodeIfPresent(PhotoColorCalibration.self, forKey: .colorCalibration)
        filmEffects = try container.decodeIfPresent(PhotoFilmEffects.self, forKey: .filmEffects) ?? .neutral
        // Both preference and per-photo archives key recipes by PhotoStyle. Use
        // that stock context: reversal already used positive = brighter in v9.
        if schemaVersion < 10,
           let key = decoder.codingPath.last?.stringValue,
           let stock = PhotoStyle(rawValue: key)?.filmStock, stock.family != "reversal" {
            filmEffects.printExposure = -filmEffects.printExposure
        }
        intensity = try container.decode(Double.self, forKey: .intensity)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        whiteBalanceWarmth = try container.decodeIfPresent(Double.self, forKey: .whiteBalanceWarmth) ?? 0
        whiteBalanceTint = try container.decodeIfPresent(Double.self, forKey: .whiteBalanceTint) ?? 0
        brightness = try container.decode(Double.self, forKey: .brightness)
        let decodedContrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? (schemaVersion < 2 ? 50 : 0)
        contrast = schemaVersion < 2 ? decodedContrast - 50 : decodedContrast
        let legacyGrain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 20
        grain = legacyGrain
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        denoise = try container.decodeIfPresent(Double.self, forKey: .denoise) ?? 0
        devignette = try container.decodeIfPresent(Double.self, forKey: .devignette) ?? 0
        backgroundBlur = try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        skinWarmth = try container.decodeIfPresent(Double.self, forKey: .skinWarmth) ?? 0
        skinWhitening = try container.decodeIfPresent(Double.self, forKey: .skinWhitening) ?? 0
        skinSmoothing = try container.decodeIfPresent(Double.self, forKey: .skinSmoothing) ?? 0
        let legacyHDREnabled = try container.decodeIfPresent(Bool.self, forKey: .hdrEnabled) ?? false
        hdrAmount = try container.decodeIfPresent(Double.self, forKey: .hdrAmount)
            ?? (legacyHDREnabled ? 25 : 0)
        hdrToneCurve = try container.decodeIfPresent(PhotoStylePlan.HDRToneCurve.self, forKey: .hdrToneCurve)
        cropAspectRatio = try container.decodeIfPresent(CropAspectRatio.self, forKey: .cropAspectRatio) ?? .original
        cropRotation = try container.decodeIfPresent(Double.self, forKey: .cropRotation) ?? 0
        cropScale = try container.decodeIfPresent(Double.self, forKey: .cropScale) ?? 100
        cropWidth = try container.decodeIfPresent(Double.self, forKey: .cropWidth) ?? 100
        cropHeight = try container.decodeIfPresent(Double.self, forKey: .cropHeight) ?? 100
        cropHorizontalPosition = try container.decodeIfPresent(Double.self, forKey: .cropHorizontalPosition) ?? 0
        cropVerticalPosition = try container.decodeIfPresent(Double.self, forKey: .cropVerticalPosition) ?? 0
        highlightExposure = try container.decodeIfPresent(Double.self, forKey: .highlightExposure) ?? 0
        highlightIntensity = try container.decodeIfPresent(Double.self, forKey: .highlightIntensity) ?? 0
        highlightWarmth = try container.decodeIfPresent(Double.self, forKey: .highlightWarmth) ?? 0
        highlightGrain = try container.decodeIfPresent(Double.self, forKey: .highlightGrain) ?? legacyGrain * 0.45
        midtoneExposure = try container.decodeIfPresent(Double.self, forKey: .midtoneExposure) ?? 0
        midtoneIntensity = try container.decodeIfPresent(Double.self, forKey: .midtoneIntensity) ?? 0
        midtoneWarmth = try container.decodeIfPresent(Double.self, forKey: .midtoneWarmth) ?? 0
        midtoneGrain = try container.decodeIfPresent(Double.self, forKey: .midtoneGrain) ?? legacyGrain * 0.75
        shadowExposure = try container.decodeIfPresent(Double.self, forKey: .shadowExposure) ?? 0
        shadowIntensity = try container.decodeIfPresent(Double.self, forKey: .shadowIntensity) ?? 0
        shadowWarmth = try container.decodeIfPresent(Double.self, forKey: .shadowWarmth) ?? 0
        shadowGrain = try container.decodeIfPresent(Double.self, forKey: .shadowGrain) ?? legacyGrain
        frameEnabled = try container.decode(Bool.self, forKey: .frameEnabled)
        frameStyle = try container.decode(FrameStyle.self, forKey: .frameStyle)
        dateEnabled = try container.decode(Bool.self, forKey: .dateEnabled)
        dateStyle = try container.decode(DateStampStyle.self, forKey: .dateStyle)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(12, forKey: .schemaVersion)
        try container.encodeIfPresent(colorCalibration, forKey: .colorCalibration)
        try container.encode(filmEffects, forKey: .filmEffects)
        try container.encode(imageScoped, forKey: .imageScoped)
        try container.encodeIfPresent(sourceToneZones, forKey: .sourceToneZones)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(whiteBalanceWarmth, forKey: .whiteBalanceWarmth)
        try container.encode(whiteBalanceTint, forKey: .whiteBalanceTint)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(grain, forKey: .grain)
        try container.encode(vignette, forKey: .vignette)
        try container.encode(denoise, forKey: .denoise)
        try container.encode(devignette, forKey: .devignette)
        try container.encode(backgroundBlur, forKey: .backgroundBlur)
        try container.encode(skinWarmth, forKey: .skinWarmth)
        try container.encode(skinWhitening, forKey: .skinWhitening)
        try container.encode(skinSmoothing, forKey: .skinSmoothing)
        try container.encode(hdrAmount, forKey: .hdrAmount)
        try container.encodeIfPresent(hdrToneCurve, forKey: .hdrToneCurve)
        try container.encode(cropAspectRatio, forKey: .cropAspectRatio)
        try container.encode(cropRotation, forKey: .cropRotation)
        try container.encode(cropScale, forKey: .cropScale)
        try container.encode(cropWidth, forKey: .cropWidth)
        try container.encode(cropHeight, forKey: .cropHeight)
        try container.encode(cropHorizontalPosition, forKey: .cropHorizontalPosition)
        try container.encode(cropVerticalPosition, forKey: .cropVerticalPosition)
        try container.encode(highlightExposure, forKey: .highlightExposure)
        try container.encode(highlightIntensity, forKey: .highlightIntensity)
        try container.encode(highlightWarmth, forKey: .highlightWarmth)
        try container.encode(highlightGrain, forKey: .highlightGrain)
        try container.encode(midtoneExposure, forKey: .midtoneExposure)
        try container.encode(midtoneIntensity, forKey: .midtoneIntensity)
        try container.encode(midtoneWarmth, forKey: .midtoneWarmth)
        try container.encode(midtoneGrain, forKey: .midtoneGrain)
        try container.encode(shadowExposure, forKey: .shadowExposure)
        try container.encode(shadowIntensity, forKey: .shadowIntensity)
        try container.encode(shadowWarmth, forKey: .shadowWarmth)
        try container.encode(shadowGrain, forKey: .shadowGrain)
        try container.encode(frameEnabled, forKey: .frameEnabled)
        try container.encode(frameStyle, forKey: .frameStyle)
        try container.encode(dateEnabled, forKey: .dateEnabled)
        try container.encode(dateStyle, forKey: .dateStyle)
    }

    static let `default` = StyleAdjustment(
        imageScoped: false,
        sourceToneZones: nil,
        intensity: 50,
        exposure: 0,
        whiteBalanceWarmth: 0,
        whiteBalanceTint: 0,
        brightness: 50,
        contrast: 0,
        grain: 20,
        vignette: 0,
        denoise: 0,
        devignette: 0,
        backgroundBlur: 0,
        skinWhitening: 0,
        skinSmoothing: 0,
        hdrAmount: 25,
        hdrToneCurve: nil,
        cropAspectRatio: .original,
        cropScale: 100,
        cropWidth: 100,
        cropHeight: 100,
        cropHorizontalPosition: 0,
        cropVerticalPosition: 0,
        highlightExposure: 0,
        highlightIntensity: 0,
        highlightWarmth: 0,
        highlightGrain: 8,
        midtoneExposure: 0,
        midtoneIntensity: 0,
        midtoneWarmth: 0,
        midtoneGrain: 14,
        shadowExposure: 0,
        shadowIntensity: 0,
        shadowWarmth: 0,
        shadowGrain: 20,
        frameEnabled: false,
        frameStyle: .whitePaperThin,
        dateEnabled: false,
        dateStyle: .numeric
    )
}

final class StyleAdjustmentStore: ObservableObject {
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

    func binding(
        for style: PhotoStyle,
        _ keyPath: WritableKeyPath<StyleAdjustment, Double>
    ) -> Binding<Double> {
        Binding(
            get: { self.adjustment(for: style)[keyPath: keyPath] },
            set: { newValue in
                self.update(style) { adjustment in
                    adjustment[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func binding(
        for style: PhotoStyle,
        _ keyPath: WritableKeyPath<StyleAdjustment, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { self.adjustment(for: style)[keyPath: keyPath] },
            set: { newValue in
                self.update(style) { adjustment in
                    adjustment[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func setFrameStyle(_ frameStyle: FrameStyle, for style: PhotoStyle) {
        update(style) { $0.frameStyle = frameStyle }
    }

    func setDateStyle(_ dateStyle: DateStampStyle, for style: PhotoStyle) {
        update(style) { $0.dateStyle = dateStyle }
    }

    func setAdjustment(_ adjustment: StyleAdjustment, for style: PhotoStyle) {
        adjustments[style] = adjustment.clamped()
        save()
    }

    // Applying a look without AI starts from that look's own processing preset.
    // Crop belongs to the photo; decorations remain the selected look's preference.
    // This is deliberately explicit so observing state never overwrites a manual edit.
    func applyDefaultAdjustment(for style: PhotoStyle, preservingCropFrom crop: StyleAdjustment? = nil) {
        setAdjustment(Self.defaultAdjustment(for: style, previous: adjustment(for: style), preservingCropFrom: crop), for: style)
    }

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

    private func update(_ style: PhotoStyle, mutate: (inout StyleAdjustment) -> Void) {
        var next = adjustment(for: style)
        mutate(&next)
        adjustments[style] = next.clamped()
        save()
    }

    private func save() {
        // Normalize legacy recipes and AI/MCP edits at the persistence boundary.
        for style in PhotoStyle.allCases where style.cameraProfile != nil {
            adjustments[style]?.filmEffects.scannerProfile = .off
        }
        let encoded = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: defaultsKey)
        onChange?()
    }
}

extension StyleAdjustment {
    static func `default`(for style: PhotoStyle) -> StyleAdjustment {
        var adjustment = StyleAdjustment.default
        if let stock = style.filmStock {
            adjustment.contrast = 0
            adjustment.hdrAmount = 0
            adjustment.grain = stock.defaultGrain
            adjustment.highlightGrain = 0
            adjustment.midtoneGrain = 0
            adjustment.shadowGrain = 0
            adjustment.filmEffects = stock.defaultEffects
            return adjustment
        }
        // Ordinary looks start without added film texture; persisted recipes
        // are read separately and retain the user's existing grain/effects.
        adjustment.grain = 0
        adjustment.highlightGrain = 0
        adjustment.midtoneGrain = 0
        adjustment.shadowGrain = 0
        adjustment.filmEffects = .neutral
        adjustment.filmEffects.monochromeFilterStrength = 0
        if style == .original || style.cameraProfile != nil { adjustment.hdrAmount = 0 }
        if style == .original { adjustment.filmEffects.scannerProfile = .neutral }
        if style == .japaneseBWStandard { adjustment.contrast = 3 }
        return adjustment
    }
}

extension StyleAdjustment {
    func clamped() -> StyleAdjustment {
        func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double = 0) -> Double {
            guard value.isFinite else { return fallback }
            return value.clamped(to: range)
        }
        let vignetteBalance = (bounded(vignette, to: 0...100) - bounded(devignette, to: 0...100))
            .clamped(to: -100...100)
        return StyleAdjustment(
            imageScoped: imageScoped,
            sourceToneZones: sourceToneZones.map(Self.normalizedToneZones),
            intensity: bounded(intensity, to: 0...100),
            exposure: bounded(exposure, to: -100...100),
            whiteBalanceWarmth: bounded(whiteBalanceWarmth, to: -100...100),
            whiteBalanceTint: bounded(whiteBalanceTint, to: -100...100),
            brightness: bounded(brightness, to: 0...100, fallback: 50),
            contrast: bounded(contrast, to: -100...100),
            grain: bounded(grain, to: 0...100),
            vignette: max(vignetteBalance, 0),
            denoise: bounded(denoise, to: 0...100),
            devignette: max(-vignetteBalance, 0),
            backgroundBlur: bounded(backgroundBlur, to: 0...100),
            skinWarmth: bounded(skinWarmth, to: -100...100),
            skinWhitening: bounded(skinWhitening, to: 0...100),
            skinSmoothing: bounded(skinSmoothing, to: 0...100),
            hdrAmount: bounded(hdrAmount, to: 0...100),
            hdrToneCurve: hdrToneCurve.map(Self.normalizedHDRToneCurve),
            cropAspectRatio: cropAspectRatio,
            cropRotation: bounded(cropRotation, to: -45...45),
            cropScale: bounded(cropScale, to: 20...100, fallback: 100),
            cropWidth: bounded(cropWidth, to: 20...100, fallback: 100),
            cropHeight: bounded(cropHeight, to: 20...100, fallback: 100),
            cropHorizontalPosition: bounded(cropHorizontalPosition, to: -100...100),
            cropVerticalPosition: bounded(cropVerticalPosition, to: -100...100),
            highlightExposure: bounded(highlightExposure, to: -100...100),
            highlightIntensity: bounded(highlightIntensity, to: 0...100),
            highlightWarmth: bounded(highlightWarmth, to: -100...100),
            highlightGrain: bounded(highlightGrain, to: 0...100),
            midtoneExposure: bounded(midtoneExposure, to: -100...100),
            midtoneIntensity: bounded(midtoneIntensity, to: 0...100),
            midtoneWarmth: bounded(midtoneWarmth, to: -100...100),
            midtoneGrain: bounded(midtoneGrain, to: 0...100),
            shadowExposure: bounded(shadowExposure, to: -100...100),
            shadowIntensity: bounded(shadowIntensity, to: 0...100),
            shadowWarmth: bounded(shadowWarmth, to: -100...100),
            shadowGrain: bounded(shadowGrain, to: 0...100),
            frameEnabled: frameEnabled,
            frameStyle: frameStyle,
            dateEnabled: dateEnabled,
            dateStyle: dateStyle,
            filmEffects: filmEffects.clamped(), colorCalibration: colorCalibration
        )
    }

    private static func normalizedToneZones(_ zones: PhotoStylePlan.ToneZones) -> PhotoStylePlan.ToneZones {
        func normalize(_ tone: PhotoStylePlan.ToneAdjustment) -> PhotoStylePlan.ToneAdjustment {
            .init(baseTone: tone.baseTone.clamped(to: -100...100),
                  exposure: tone.exposure.clamped(to: -100...100),
                  contrast: tone.contrast.clamped(to: -100...100),
                  softness: tone.softness.clamped(to: 0...100),
                  grain: tone.grain.clamped(to: 0...100),
                  highlights: tone.highlights.clamped(to: -100...100),
                  shadows: tone.shadows.clamped(to: -100...100),
                  fade: tone.fade.clamped(to: 0...100),
                  warmth: tone.warmth.clamped(to: -100...100),
                  tint: tone.tint.clamped(to: -100...100),
                  mapping: tone.mapping.clamped(to: 0...100))
        }
        return .init(shadows: normalize(zones.shadows), midtones: normalize(zones.midtones), highlights: normalize(zones.highlights))
    }

    private static func normalizedHDRToneCurve(_ curve: PhotoStylePlan.HDRToneCurve) -> PhotoStylePlan.HDRToneCurve {
        let black = curve.black.clamped(to: 0...100)
        let shadows = max(black, curve.shadows.clamped(to: 0...100))
        let midtones = max(shadows, curve.midtones.clamped(to: 0...100))
        let highlights = max(midtones, curve.highlights.clamped(to: 0...100))
        let white = max(highlights, curve.white.clamped(to: 0...100))
        return .init(black: black, shadows: shadows, midtones: midtones, highlights: highlights,
                     white: white, detail: curve.detail.clamped(to: 0...40))
    }

}
