import Foundation

extension PhotoFilmStock {
    /// Starting values for newly selected stocks, not chemical measurements.
    /// Contrast is relative to each existing stock curve; missing saved recipe fields use these defaults.
    public var developerDefaults: PhotoDeveloperSettings {
        switch self {
        case .filmPortra160: return .init(contrast: 0.94, speedEV: 0.03, compensation: 24, grain: 3, acutance: 12, red: 1, green: 0, blue: -1)
        case .filmPortra400: return .init(contrast: 0.96, speedEV: 0.05, compensation: 30, grain: 7, acutance: 12, red: 1.5, green: 0.5, blue: -1)
        case .filmPortra800: return .init(contrast: 0.92, speedEV: 0.10, compensation: 36, grain: 13, acutance: 8, red: 2, green: 0.5, blue: -1)
        case .filmEktar100: return .init(contrast: 1.08, compensation: 20, grain: 2, acutance: 24, red: 1, green: -0.5, blue: 1)
        case .filmVision50D: return .init(contrast: 0.96, speedEV: 0.03, compensation: 45, grain: 2, acutance: 18, red: 0.5, green: 0, blue: -0.5)
        case .filmVision250D: return .init(contrast: 0.94, speedEV: 0.06, compensation: 48, grain: 6, acutance: 15, red: 1, green: 0, blue: -1)
        case .filmVision200T: return .init(contrast: 0.94, speedEV: 0.06, compensation: 46, grain: 5, acutance: 16, red: 1.5, green: 0.5, blue: -1.5)
        case .filmVision500T: return .init(contrast: 0.91, speedEV: 0.12, compensation: 52, grain: 12, acutance: 10, red: 2, green: 0.5, blue: -2)
        case .filmEktachrome100: return .init(contrast: 1.04, compensation: 20, grain: 3, acutance: 24, red: 0, green: 0, blue: 1)
        case .filmVelvia50: return .init(contrast: 1.12, compensation: 16, grain: 2, acutance: 26, red: 1, green: 1.5, blue: -1)
        case .filmProvia100F: return .init(contrast: 1.02, compensation: 26, grain: 3, acutance: 22)
        case .filmHP5: return .init(contrast: 1.07, speedEV: 0.05, compensation: 30, grain: 18, acutance: 18)
        case .filmFP4: return .init(contrast: 1.03, compensation: 24, grain: 6, acutance: 26)
        case .filmOrtho80: return .init(contrast: 1.06, speedEV: -0.03, compensation: 22, grain: 4, acutance: 28)
        case .filmSFX200: return .init(contrast: 1.04, compensation: 28, grain: 12, acutance: 20)
        case .filmInfrared400: return .init(contrast: 1.08, compensation: 32, grain: 14, acutance: 22)
        case .filmDelta3200: return .init(contrast: 0.92, speedEV: 0.18, compensation: 44, grain: 30, acutance: 8)
        case .filmBleachBypass: return .init(contrast: 1.08, compensation: 22, grain: 16, acutance: 20)
        case .filmCrossProcess: return .init(contrast: 1.06, compensation: 20, grain: 9, acutance: 14, red: 8, green: -3, blue: -6)
        case .filmGold200: return .init(contrast: 1.03, speedEV: 0.03, compensation: 24, grain: 10, acutance: 14, red: 2.5, green: 0.5, blue: -2)
        case .filmCineStill800T: return .init(contrast: 0.94, speedEV: 0.10, compensation: 48, grain: 15, acutance: 8, red: 2, green: 0.5, blue: -2)
        case .filmPolaroidSX70: return .init(contrast: 0.90, speedEV: 0.03, compensation: 38, grain: 4, acutance: 0, red: 1.5, green: 0.5, blue: -1)
        case .filmLomoPurple: return .init(contrast: 1.02, compensation: 26, grain: 9, acutance: 12, red: -1, green: 2, blue: 1)
        }
    }
}
