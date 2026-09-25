import Foundation

/// Film controls shared by saved adjustments, generated plans and both renderers.
/// Grain amount remains in the existing global/tonal grain controls. Size uses
/// pixels at a 3000-pixel full-frame long edge; glow radii are percentages of that
/// long edge (Gaussian sigma), so previews and exports describe the same effect.
public struct PhotoFilmEffects: Codable, Equatable, Sendable {
    /// 視覺強度控制：提高低、中段響應，0 仍關閉，100 保留原最大作用量。
    static func effectAmount(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return sqrt(min(100, max(0, value)) / 100)
    }

    /// UI 門檻以可見亮度百分比表示，轉換後才比較線性光能量。
    static func linearLightThreshold(_ value: Double) -> Double {
        let level = min(100, max(0, value.isFinite ? value : 75)) / 100
        return level <= 0.04045 ? level / 12.92 : pow((level + 0.055) / 1.055, 2.4)
    }

    public static let printExposureRange: ClosedRange<Double> = -4...4

    public enum ScannerProfile: String, Codable, CaseIterable, Sendable {
        case off, neutral, warmCool
    }

    public enum GrainMode: String, Codable, CaseIterable, Sendable {
        // Old raw values remain readable for saved recipes and client compatibility.
        case legacy, structured, crystal, emulsion
        public static let allCases: [Self] = [.emulsion]
    }

    public enum Illuminant: String, Codable, CaseIterable, Sendable {
        case reference, tungsten2856, blackbody3200, blackbody4000, blackbody5000
        case blackbody5500, blackbody6500, blackbody7500, blackbody10000

        public var temperature: Double? {
            switch self {
            case .reference: nil
            case .tungsten2856: 2856
            case .blackbody3200: 3200
            case .blackbody4000: 4000
            case .blackbody5000: 5000
            case .blackbody5500: 5500
            case .blackbody6500: 6500
            case .blackbody7500: 7500
            case .blackbody10000: 10000
            }
        }

        public var title: String {
            temperature.map { "黑體 \(Int($0)) K" } ?? "原始參考"
        }
    }

    public enum ColorModel: String, Codable, CaseIterable, Sendable {
        case analytic, spectral
        public static let allCases: [Self] = [.spectral]
    }

    public enum MonochromeFilter: String, Codable, CaseIterable, Sendable {
        case none, yellow, orange, red, green
    }

    public var grainMode: GrainMode
    public var grainSize: Double
    public var grainClumping: Double
    public var grainChroma: Double
    public var bloomAmount: Double
    public var bloomRadius: Double
    public var bloomThreshold: Double
    public var halationAmount: Double
    public var halationRadius: Double
    public var halationThreshold: Double
    public var monochromeFilter: MonochromeFilter
    public var monochromeFilterStrength: Double
    public var colorModel: ColorModel
    /// Output exposure compensation in EV: positive brightens every stock.
    /// Negative-film printing internally uses the opposite paper-exposure sign.
    // Runtime preference; excluded from saved film recipes.
    public var highlightProtectionEnabled = true
    public var printExposure: Double
    public var printContrast: Double
    public var printIlluminant: Illuminant
    public var viewIlluminant: Illuminant
    public var developmentAmount: Double
    public var developmentTime: Double
    public var developmentDiffusion: Double
    public var developmentAgitation: Double

    public var scannerProfile: ScannerProfile
    public var scannerIlluminant: Illuminant
    public var scanExposure: Double
    public var scanContrast: Double
    public var scanSaturation: Double
    public var scanDensityCorrection: Double
    public var scanFlare: Double
    public var scanMidtoneWarmth: Double
    public var scanHighlightWarmth: Double

    public static let neutral = PhotoFilmEffects()

    public init(
        highlightProtectionEnabled: Bool = true,
        grainMode: GrainMode = .emulsion,
        grainSize: Double = 1,
        grainClumping: Double = 0,
        grainChroma: Double = 0,
        bloomAmount: Double = 0,
        bloomRadius: Double = 0.4,
        bloomThreshold: Double = 75,
        halationAmount: Double = 0,
        halationRadius: Double = 0.1,
        halationThreshold: Double = 75,
        monochromeFilter: MonochromeFilter = .none,
        monochromeFilterStrength: Double = 100,
        colorModel: ColorModel = .spectral,
        printExposure: Double = 0,
        printContrast: Double = 50,
        printIlluminant: Illuminant = .reference,
        viewIlluminant: Illuminant = .reference,
        developmentAmount: Double = 0,
        developmentTime: Double = 50,
        developmentDiffusion: Double = 0.15,
        developmentAgitation: Double = 50,
        scannerProfile: ScannerProfile = .off,
        scannerIlluminant: Illuminant = .reference,
        scanExposure: Double = 0,
        scanContrast: Double = 50,
        scanSaturation: Double = 50,
        scanDensityCorrection: Double = 100,
        scanFlare: Double = 0,
        scanMidtoneWarmth: Double = 0,
        scanHighlightWarmth: Double = 0
    ) {
        // Retired engine identifiers are accepted on input but canonicalized.
        self.highlightProtectionEnabled = highlightProtectionEnabled
        self.grainMode = .emulsion
        self.grainSize = grainSize
        self.grainClumping = grainClumping
        self.grainChroma = grainChroma
        self.bloomAmount = bloomAmount
        self.bloomRadius = bloomRadius
        self.bloomThreshold = bloomThreshold
        self.halationAmount = halationAmount
        self.halationRadius = halationRadius
        self.halationThreshold = halationThreshold
        self.monochromeFilter = monochromeFilter
        self.monochromeFilterStrength = monochromeFilterStrength
        self.colorModel = .spectral
        self.printExposure = printExposure
        self.printContrast = printContrast
        self.printIlluminant = printIlluminant
        self.viewIlluminant = viewIlluminant
        self.developmentAmount = developmentAmount
        self.developmentTime = developmentTime
        self.developmentDiffusion = developmentDiffusion
        self.developmentAgitation = developmentAgitation
        self.scannerProfile = scannerProfile
        self.scannerIlluminant = scannerIlluminant
        self.scanExposure = scanExposure
        self.scanContrast = scanContrast
        self.scanSaturation = scanSaturation
        self.scanDensityCorrection = scanDensityCorrection
        self.scanFlare = scanFlare
        self.scanMidtoneWarmth = scanMidtoneWarmth
        self.scanHighlightWarmth = scanHighlightWarmth
    }

    public func clamped() -> PhotoFilmEffects {
        func bound(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double = 0) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        return PhotoFilmEffects(
            highlightProtectionEnabled: highlightProtectionEnabled,
            grainMode: grainMode,
            grainSize: bound(grainSize, 0.5...4, 1),
            grainClumping: bound(grainClumping, 0...100),
            grainChroma: bound(grainChroma, 0...100),
            bloomAmount: bound(bloomAmount, 0...100),
            bloomRadius: bound(bloomRadius, 0.05...2, 0.4),
            bloomThreshold: bound(bloomThreshold, 0...100, 75),
            halationAmount: bound(halationAmount, 0...100),
            halationRadius: bound(halationRadius, 0.01...0.3, 0.1),
            halationThreshold: bound(halationThreshold, 0...100, 75),
            monochromeFilter: monochromeFilter,
            monochromeFilterStrength: bound(monochromeFilterStrength, 0...100, 100),
            colorModel: colorModel,
            printExposure: bound(printExposure, Self.printExposureRange),
            printContrast: bound(printContrast, 0...100, 50),
            printIlluminant: printIlluminant, viewIlluminant: viewIlluminant,
            developmentAmount: bound(developmentAmount, 0...100),
            developmentTime: bound(developmentTime, 0...100, 50),
            developmentDiffusion: bound(developmentDiffusion, 0.02...1, 0.15),
            developmentAgitation: bound(developmentAgitation, 0...100, 50),
            scannerProfile: scannerProfile,
            scannerIlluminant: scannerIlluminant,
            scanExposure: bound(scanExposure, -4...4, 0),
            scanContrast: bound(scanContrast, 0...100, 50),
            scanSaturation: bound(scanSaturation, 0...100, 50),
            scanDensityCorrection: bound(scanDensityCorrection, 0...100, 100),
            scanFlare: bound(scanFlare, 0...100, 0),
            scanMidtoneWarmth: bound(scanMidtoneWarmth, -100...100, 0),
            scanHighlightWarmth: bound(scanHighlightWarmth, -100...100, 0)
        )
    }

    enum CodingKeys: String, CodingKey {
        case grainMode = "grain_mode"
        case grainSize = "grain_size"
        case grainClumping = "grain_clumping"
        case grainChroma = "grain_chroma"
        case bloomAmount = "bloom_amount"
        case bloomRadius = "bloom_radius"
        case bloomThreshold = "bloom_threshold"
        case halationAmount = "halation_amount"
        case halationRadius = "halation_radius"
        case halationThreshold = "halation_threshold"
        case monochromeFilter = "monochrome_filter"
        case monochromeFilterStrength = "monochrome_filter_strength"
        case colorModel = "color_model"
        case printExposure = "print_exposure"
        case printContrast = "print_contrast"
        case printIlluminant = "print_illuminant"
        case viewIlluminant = "view_illuminant"
        case developmentAmount = "development_amount"
        case developmentTime = "development_time"
        case developmentDiffusion = "development_diffusion"
        case developmentAgitation = "development_agitation"
        case scannerProfile = "scanner_profile"
        case scannerIlluminant = "scanner_illuminant"
        case scanExposure = "scan_exposure"
        case scanContrast = "scan_contrast"
        case scanSaturation = "scan_saturation"
        case scanDensityCorrection = "scan_density_correction"
        case scanFlare = "scan_flare"
        case scanMidtoneWarmth = "scan_midtone_warmth"
        case scanHighlightWarmth = "scan_highlight_warmth"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            grainMode: try values.decodeIfPresent(GrainMode.self, forKey: .grainMode) ?? .legacy,
            grainSize: try values.decodeIfPresent(Double.self, forKey: .grainSize) ?? 1,
            grainClumping: try values.decodeIfPresent(Double.self, forKey: .grainClumping) ?? 0,
            grainChroma: try values.decodeIfPresent(Double.self, forKey: .grainChroma) ?? 0,
            bloomAmount: try values.decodeIfPresent(Double.self, forKey: .bloomAmount) ?? 0,
            bloomRadius: try values.decodeIfPresent(Double.self, forKey: .bloomRadius) ?? 0.4,
            bloomThreshold: try values.decodeIfPresent(Double.self, forKey: .bloomThreshold) ?? 75,
            halationAmount: try values.decodeIfPresent(Double.self, forKey: .halationAmount) ?? 0,
            halationRadius: try values.decodeIfPresent(Double.self, forKey: .halationRadius) ?? 0.1,
            halationThreshold: try values.decodeIfPresent(Double.self, forKey: .halationThreshold) ?? 75,
            monochromeFilter: try values.decodeIfPresent(MonochromeFilter.self, forKey: .monochromeFilter) ?? .none,
            monochromeFilterStrength: try values.decodeIfPresent(Double.self, forKey: .monochromeFilterStrength) ?? 100,
            colorModel: try values.decodeIfPresent(ColorModel.self, forKey: .colorModel) ?? .analytic,
            printExposure: try values.decodeIfPresent(Double.self, forKey: .printExposure) ?? 0,
            printContrast: try values.decodeIfPresent(Double.self, forKey: .printContrast) ?? 50,
            printIlluminant: try values.decodeIfPresent(Illuminant.self, forKey: .printIlluminant) ?? .reference,
            viewIlluminant: try values.decodeIfPresent(Illuminant.self, forKey: .viewIlluminant) ?? .reference,
            developmentAmount: try values.decodeIfPresent(Double.self, forKey: .developmentAmount) ?? 0,
            developmentTime: try values.decodeIfPresent(Double.self, forKey: .developmentTime) ?? 50,
            developmentDiffusion: try values.decodeIfPresent(Double.self, forKey: .developmentDiffusion) ?? 0.15,
            developmentAgitation: try values.decodeIfPresent(Double.self, forKey: .developmentAgitation) ?? 50,
            scannerProfile: try values.decodeIfPresent(ScannerProfile.self, forKey: .scannerProfile) ?? .off,
            scannerIlluminant: try values.decodeIfPresent(Illuminant.self, forKey: .scannerIlluminant) ?? .reference,
            scanExposure: try values.decodeIfPresent(Double.self, forKey: .scanExposure) ?? 0,
            scanContrast: try values.decodeIfPresent(Double.self, forKey: .scanContrast) ?? 50,
            scanSaturation: try values.decodeIfPresent(Double.self, forKey: .scanSaturation) ?? 50,
            scanDensityCorrection: try values.decodeIfPresent(Double.self, forKey: .scanDensityCorrection) ?? 100,
            scanFlare: try values.decodeIfPresent(Double.self, forKey: .scanFlare) ?? 0,
            scanMidtoneWarmth: try values.decodeIfPresent(Double.self, forKey: .scanMidtoneWarmth) ?? 0,
            scanHighlightWarmth: try values.decodeIfPresent(Double.self, forKey: .scanHighlightWarmth) ?? 0
        )
    }
}
