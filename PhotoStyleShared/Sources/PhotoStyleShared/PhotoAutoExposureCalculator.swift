import Foundation

public enum PhotoAutoExposureCalculator {
    public static func exposureEV(p50: Double, mean: Double, p95: Double) -> Double {
        var exposureEV = log2(0.20 / max(p50, 0.015))
        if mean < 0.12 {
            exposureEV = max(exposureEV, log2(0.16 / max(mean, 0.015)))
        } else if mean > 0.45 {
            exposureEV = min(exposureEV, log2(0.36 / max(mean, 0.015)))
        }
        if exposureEV > 0, p95 > 0.72 {
            exposureEV = min(exposureEV, log2(0.94 / max(p95, 0.015)))
        }
        return min(max(exposureEV, -1.2), 1.2)
    }

    public static func sliderValue(p50: Double, mean: Double, p95: Double) -> Double {
        let exposureEV = exposureEV(p50: p50, mean: mean, p95: p95)
        return abs(exposureEV) < 0.12 ? 0 : PhotoExposureScale.sliderValue(fromEV: exposureEV)
    }
}
