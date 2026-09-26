import Foundation
import simd

/// Linear-luminance exposure with an optional smooth highlight shoulder.
/// Lab lightness and chroma are separated; existing HDR headroom is retained.
/// This is pointwise: no statistics, masks or additional image buffers.
enum PhotoExposureProtection {
    /// Keep a fixed middle band and smoothly approach each zone's requested EV.
    /// The previous EV-dependent transition width made +8 lift LESS than +2.
    /// Here a positive distance d from the middle band uses the coordinate
    /// phi(d) = width - k*cot(d/k), k = 2*width/pi, until d reaches width;
    /// beyond that phi(d) = d. Shifting phi by EV and inverting it is monotone
    /// in both input luminance and slider value. Its speed is sin²(d/k), joining
    /// zero at the middle boundary and exact EV in the tail with smooth slopes.
    /// This is a closed-form point operation, with no iterative image processing.
    static func exposureEV(_ rgb: SIMD3<Double>, zones: SIMD3<Double>) -> Double {
        if zones.x == zones.y && zones.z == zones.y { return zones.y }
        let y = simd_dot(rgb, PhotoExposureColor.luminanceWeights)
        let stops = log2(max(y, 1e-20) / 0.18)
        if stops < -1 {
            return zones.y + zoneOffset(distance: -1-stops, delta: zones.z-zones.y, width: 3, direction: -1)
        }
        if stops > 0 {
            return zones.y + zoneOffset(distance: stops, delta: zones.x-zones.y, width: 1.5, direction: 1)
        }
        return zones.y
    }

    private static func zoneOffset(distance d: Double, delta: Double, width: Double, direction: Double) -> Double {
        guard d > 1e-6, delta != 0 else { return 0 }
        let k = 2 * width / Double.pi
        let coordinate = d >= width ? d : width - k / tan(d/k)
        let shifted = coordinate + direction * delta
        if d >= width && shifted >= width { return delta }
        let target = shifted >= width ? shifted : k * atan(k / (width-shifted))
        return min(max(0, delta), max(min(0, delta), direction * (target-d)))
    }

    static let zoneKernel = """
    float zoneExposureOffset(float d, float delta, float width, float direction) {
        if (d <= 1.0e-6 || delta == 0.0) { return 0.0; }
        float k = 0.6366197723675814 * width;
        float coordinate = d >= width ? d : width - k / tan(d / k);
        float shifted = coordinate + direction * delta;
        if (d >= width && shifted >= width) { return delta; }
        float target = shifted >= width ? shifted : k * atan(k / (width - shifted));
        return clamp(direction * (target - d), min(0.0, delta), max(0.0, delta));
    }
    float zoneExposureEV(float y, vec3 ev) {
        if (ev.x == ev.y && ev.z == ev.y) { return ev.y; }
        float stops = log2(max(y, 1.0e-20) / 0.18);
        if (stops < -1.0) {
            return ev.y + zoneExposureOffset(-1.0 - stops, ev.z - ev.y, 3.0, -1.0);
        }
        if (stops > 0.0) {
            return ev.y + zoneExposureOffset(stops, ev.x - ev.y, 1.5, 1.0);
        }
        return ev.y;
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
