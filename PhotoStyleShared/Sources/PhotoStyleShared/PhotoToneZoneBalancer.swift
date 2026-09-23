public struct PhotoToneZoneBalance: Equatable, Sendable {
    public let common: Double
    public let shadows: Double
    public let midtones: Double
    public let highlights: Double

    public init(common: Double, shadows: Double, midtones: Double, highlights: Double) {
        self.common = common
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
    }
}

public enum PhotoToneZoneBalancer {
    public static func balance(
        shadows: Double,
        midtones: Double,
        highlights: Double,
        commonScale: Double = 1,
        residualScale: Double = 1,
        commonLimits: ClosedRange<Double> = -100...100,
        residualLimits: ClosedRange<Double> = -100...100
    ) -> PhotoToneZoneBalance {
        let weightedMean = shadows * 0.25 + midtones * 0.55 + highlights * 0.20
        return PhotoToneZoneBalance(
            common: clamp(weightedMean * commonScale, to: commonLimits),
            shadows: clamp((shadows - weightedMean) * residualScale, to: residualLimits),
            midtones: clamp((midtones - weightedMean) * residualScale, to: residualLimits),
            highlights: clamp((highlights - weightedMean) * residualScale, to: residualLimits)
        )
    }

    private static func clamp(_ value: Double, to limits: ClosedRange<Double>) -> Double {
        min(max(value, limits.lowerBound), limits.upperBound)
    }
}
