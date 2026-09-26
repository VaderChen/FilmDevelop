import Foundation
import simd

/// Linear-luminance exposure with an optional smooth highlight shoulder.
/// Lab lightness and chroma are separated; existing HDR headroom is retained.
/// This is pointwise: no statistics, masks or additional image buffers.
enum PhotoExposureProtection {
    /// Integrate a local exposure velocity in log luminance. The nonnegative
    /// weights sum to one, so equal controls remain literal global EV. A zero
    /// neighboring zone is a fixed boundary, not a residual of middle exposure.
    /// 64 Euler steps keep the map strictly increasing: on [-16,16] controls,
    /// the worst velocity slope is 32 stops/stop (1.5-stop smoothstep overlap).
    /// Each step therefore has derivative >= 0.5, and is monotone in every EV.
    /// This stays pointwise on the GPU; no masks or image buffers are added.
    static func exposureEV(_ rgb: SIMD3<Double>, zones: SIMD3<Double>) -> Double {
        if zones.x == zones.y && zones.z == zones.y { return zones.y }
        let y = simd_dot(rgb, PhotoExposureColor.luminanceWeights)
        let origin = log2(max(y, 1e-20) / 0.18)
        var position = origin
        func smooth(_ value: Double) -> Double {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        for step in 0..<64 {
            let remaining = Double(64-step) / 64
            if position <= -4 && position + zones.z * remaining <= -4 {
                position += zones.z * remaining
                break
            }
            if position >= 1.5 && position + zones.x * remaining >= 1.5 {
                position += zones.x * remaining
                break
            }
            let shadow = 1-smooth((position+4)/3)
            let highlight = smooth(position/1.5)
            let velocity = shadow*zones.z + highlight*zones.x + (1-shadow-highlight)*zones.y
            if velocity == 0 { break }
            position += velocity / 64
        }
        return position-origin
    }

    static let zoneKernel = """
    float zoneExposureEV(float y, vec3 ev) {
        if (ev.x == ev.y && ev.z == ev.y) { return ev.y; }
        float origin = log2(max(y, 1.0e-20) / 0.18);
        float position = origin;
        for (int step = 0; step < 64; ++step) {
            float remaining = float(64-step) / 64.0;
            if (position <= -4.0 && position + ev.z * remaining <= -4.0) {
                position += ev.z * remaining;
                break;
            }
            if (position >= 1.5 && position + ev.x * remaining >= 1.5) {
                position += ev.x * remaining;
                break;
            }
            float shadow = 1.0-smoothstep(-4.0, -1.0, position);
            float highlight = smoothstep(0.0, 1.5, position);
            float velocity = shadow*ev.z + highlight*ev.x + (1.0-shadow-highlight)*ev.y;
            if (velocity == 0.0) { break; }
            position += velocity / 64.0;
        }
        return position-origin;
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

    /// 線性亮度的曝光倍率；RGB 重建由 Lab 亮度／色度分離處理。
    static func luminanceGain(_ rgb: SIMD3<Double>, gain: Double, protectsHighlights: Bool) -> Double {
        let y = simd_dot(rgb, PhotoExposureColor.luminanceWeights)
        guard y > 1e-20, protectsHighlights, gain > 1 else { return gain }
        return peak(y, gain: gain) / y
    }

    static func applyLuminance(_ rgb: SIMD3<Double>, gain: Double, protectsHighlights: Bool) -> SIMD3<Double> {
        let ceiling = protectsHighlights && gain > 1 ? max(1, max(rgb.x, max(rgb.y, rgb.z))) : Double.infinity
        return PhotoExposureColor.replacingLuminance(rgb,
            scale: luminanceGain(rgb, gain: gain, protectsHighlights: protectsHighlights), ceiling: ceiling)
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
