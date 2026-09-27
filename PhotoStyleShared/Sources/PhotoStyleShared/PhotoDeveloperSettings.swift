import Foundation

/// Developer response relative to the stock curve. Recipe loaders supply stock defaults.
public struct PhotoDeveloperSettings: Codable, Equatable, Sendable {
    public var contrast: Double
    public var speedEV: Double
    public var compensation: Double
    public var grain: Double
    public var acutance: Double
    public var red: Double
    public var green: Double
    public var blue: Double

    public static let neutral = PhotoDeveloperSettings()
    public init(contrast: Double = 1, speedEV: Double = 0, compensation: Double = 0,
                grain: Double = 0, acutance: Double = 0,
                red: Double = 0, green: Double = 0, blue: Double = 0) {
        self.contrast = contrast; self.speedEV = speedEV; self.compensation = compensation
        self.grain = grain; self.acutance = acutance
        self.red = red; self.green = green; self.blue = blue
    }

    /// One registry for native validation, state and adjustment updates.
    public enum Control: String, CaseIterable, Sendable {
        case developerContrast, developerSpeed, developerCompensation, developerGrain
        case developerAcutance, developerRed, developerGreen, developerBlue
        var path: WritableKeyPath<PhotoDeveloperSettings, Double> {
            switch self {
            case .developerContrast: return \.contrast
            case .developerSpeed: return \.speedEV
            case .developerCompensation: return \.compensation
            case .developerGrain: return \.grain
            case .developerAcutance: return \.acutance
            case .developerRed: return \.red
            case .developerGreen: return \.green
            case .developerBlue: return \.blue
            }
        }
        public var range: ClosedRange<Double> {
            switch self {
            case .developerContrast: return 0.6...1.5
            case .developerSpeed: return -1...1
            case .developerRed, .developerGreen, .developerBlue: return -20...20
            default: return 0...100
            }
        }
    }
    public subscript(_ control: Control) -> Double {
        get { self[keyPath: control.path] }
        set { self[keyPath: control.path] = newValue }
    }
    public func clamped() -> Self {
        var result = self
        for control in Control.allCases {
            let value = self[control], range = control.range
            result[control] = value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : Self.neutral[control]
        }
        return result
    }
    enum CodingKeys: String, CodingKey { case contrast, speedEV, compensation, grain, acutance, red, green, blue }
    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: .neutral)
    }
    public init(from decoder: Decoder, defaults: Self) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        self.init(contrast: try v.decodeIfPresent(Double.self, forKey: .contrast) ?? defaults.contrast,
                  speedEV: try v.decodeIfPresent(Double.self, forKey: .speedEV) ?? defaults.speedEV,
                  compensation: try v.decodeIfPresent(Double.self, forKey: .compensation) ?? defaults.compensation,
                  grain: try v.decodeIfPresent(Double.self, forKey: .grain) ?? defaults.grain,
                  acutance: try v.decodeIfPresent(Double.self, forKey: .acutance) ?? defaults.acutance,
                  red: try v.decodeIfPresent(Double.self, forKey: .red) ?? defaults.red,
                  green: try v.decodeIfPresent(Double.self, forKey: .green) ?? defaults.green,
                  blue: try v.decodeIfPresent(Double.self, forKey: .blue) ?? defaults.blue)
        self = clamped()
    }
}
