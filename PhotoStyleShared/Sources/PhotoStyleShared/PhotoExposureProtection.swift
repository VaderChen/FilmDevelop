import Foundation
import simd

/// Linear-luminance exposure with an optional smooth highlight shoulder.
/// A common RGB gain preserves chromaticity and existing HDR headroom.
/// This is pointwise: no statistics, masks or additional image buffers.
enum PhotoExposureProtection {
    /// Fit the requested shadow/middle/highlight offsets at -6/-1/+2 stops
    /// relative to 18% gray. A least-squares projection keeps both intervening
    /// slopes in 0.5...2. Extreme local edits therefore spread gently into
    /// neighboring tones instead of collapsing them against a fixed boundary.
    /// The result is (shadow-tail EV, first slope, second slope), computed once
    /// per adjustment and shared by the CPU reference and GPU pixel function.
    static func curveParameters(zones: SIMD3<Double>) -> SIMD3<Double> {
        guard zones.x.isFinite, zones.y.isFinite, zones.z.isFinite else {
            return SIMD3(0, 1, 1)
        }
        if zones.x == zones.y && zones.z == zones.y { return SIMD3(zones.y, 1, 1) }
        let anchors = SIMD3<Double>(-6, -1, 2)
        let target = anchors + SIMD3(zones.z, zones.y, zones.x)
        // C * knots >= limits expresses lower and upper secant bounds.
        let rows = [SIMD3<Double>(-1, 1, 0), SIMD3(1, -1, 0),
                    SIMD3(0, -1, 1), SIMD3(0, 1, -1)]
        let limits = [2.5, -10.0, 1.5, -6.0]
        // A common translation is always feasible. At most two independent
        // constraints can bind because every row is orthogonal to (1,1,1).
        var best = anchors + SIMD3(repeating: (zones.x + zones.y + zones.z) / 3)
        var bestLoss = simd_length_squared(best - target)
        func consider(_ candidate: SIMD3<Double>) {
            for i in rows.indices where simd_dot(rows[i], candidate) < limits[i] - 1e-10 { return }
            let loss = simd_length_squared(candidate - target)
            if loss < bestLoss { best = candidate; bestLoss = loss }
        }
        consider(target)
        for i in rows.indices {
            let first = rows[i]
            let residual = limits[i] - simd_dot(first, target)
            consider(target + first * (residual / 2))
            for j in (i + 1)..<rows.count {
                let second = rows[j]
                let cross = simd_dot(first, second)
                let determinant = 4 - cross * cross
                guard determinant > 0 else { continue }
                let otherResidual = limits[j] - simd_dot(second, target)
                let firstWeight = (2 * residual - cross * otherResidual) / determinant
                let secondWeight = (2 * otherResidual - cross * residual) / determinant
                consider(target + first * firstWeight + second * secondWeight)
            }
        }
        return SIMD3(best.x + 6, (best.y - best.x) / 5, (best.z - best.y) / 3)
    }

    static func exposureEV(_ rgb: SIMD3<Double>, zones: SIMD3<Double>) -> Double {
        exposureEV(luminance: simd_dot(rgb, PhotoExposureColor.luminanceWeights),
                   curve: curveParameters(zones: zones))
    }

    /// Smoothing the piecewise-linear curve with softplus makes its derivative
    /// a convex combination of [1, first slope, second slope, 1]. Thus local
    /// log contrast stays within 0.5...2 everywhere, including the smooth joins.
    /// Global exposure is added separately by the caller after this local EV.
    static func exposureEV(luminance: Double, curve: SIMD3<Double>) -> Double {
        if curve.y == 1 && curve.z == 1 { return curve.x }
        let x = log2(max(luminance, 1e-20) / 0.18)
        func softplus(_ value: Double) -> Double {
            max(value, 0) + 0.4 * log1p(exp(-abs(value) / 0.4))
        }
        let first = softplus(x + 6)
        let middle = softplus(x + 1)
        let last = softplus(x - 2)
        return curve.x + (curve.y - 1) * (first - middle) + (curve.z - 1) * (middle - last)
    }

    static let zoneKernel = """
    float exposureSoftplus(float value) {
        return max(value, 0.0) + 0.4 * log(1.0 + exp(-abs(value) / 0.4));
    }
    // curve is precomputed on the CPU: (shadow-tail EV, first slope, second slope).
    float zoneExposureEV(float y, vec3 curve) {
        if (curve.y == 1.0 && curve.z == 1.0) { return curve.x; }
        float x = log2(max(y, 1.0e-20) / 0.18);
        float first = exposureSoftplus(x + 6.0);
        float middle = exposureSoftplus(x + 1.0);
        float last = exposureSoftplus(x - 2.0);
        return curve.x + (curve.y - 1.0) * (first - middle) + (curve.z - 1.0) * (middle - last);
    }

    """

    static func peak(_ value: Double, gain: Double) -> Double {
        if gain == 1 || value <= 0 { return value }
        if gain < 1 {
            return value * gain
        }
        if value >= 1 { return value }
        let knee = 0.6
        let start = knee / gain
        if value <= start { return value * gain }
        let distance = value - start
        let curvature = gain / (1 - knee) - 1 / (1 - start)
        return knee + gain * distance / (1 + curvature * distance)
    }

    static func apply(_ rgb: SIMD3<Double>, gain: Double) -> SIMD3<Double> {
        guard gain != 1 else { return rgb }
        let maximum = max(rgb.x, max(rgb.y, rgb.z))
        return rgb * (maximum > 1e-8 ? peak(maximum, gain: gain) / maximum : gain)
    }

    /// 以線性亮度決定共同 RGB 增益；不固定 Lab 色度。
    static func luminanceGain(_ rgb: SIMD3<Double>, gain: Double, protectsHighlights: Bool, protectsPeak: Bool = false) -> Double {
        let y = protectsPeak ? max(rgb.x, max(rgb.y, rgb.z)) : simd_dot(rgb, PhotoExposureColor.luminanceWeights)
        guard y > 1e-20, protectsHighlights, gain > 1 else { return gain }
        return peak(y, gain: gain) / y
    }

    static func applyLuminance(_ rgb: SIMD3<Double>, gain: Double, protectsHighlights: Bool, protectsPeak: Bool = false) -> SIMD3<Double> {
        rgb * luminanceGain(rgb, gain: gain, protectsHighlights: protectsHighlights, protectsPeak: protectsPeak)
    }

    // Shared syntax supported by both Core Image Kernel Language and Metal.
    // The shoulder joins linear exposure with the same slope, maps white to
    // white, and remains strictly increasing below white. Negative EV always
    // uses the exact linear-light gain without an automatic shadow lift.
    static let kernel = """
    float protectedExposurePeak(float value, float gain) {
        if (gain == 1.0 || value <= 0.0) { return value; }
        if (gain < 1.0) {
            return value * gain;
        }
        if (value >= 1.0) { return value; }
        float knee = 0.6;
        float start = knee / gain;
        if (value <= start) { return value * gain; }
        float distance = value - start;
        float curvature = gain / (1.0 - knee) - 1.0 / (1.0 - start);
        return knee + gain * distance / (1.0 + curvature * distance);
    }
    """
}
