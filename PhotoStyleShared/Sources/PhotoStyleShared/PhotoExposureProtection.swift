import Foundation
import simd

/// Display exposure with a smooth shoulder and shadow toe. A single gain for
/// RGB preserves channel ratios; existing HDR headroom is never clipped away.
/// This is pointwise: no statistics, masks or additional image buffers.
enum PhotoExposureProtection {
    static func peak(_ value: Double, gain: Double) -> Double {
        if gain == 1 || value <= 0 { return value }
        if gain < 1 {
            return value * (gain + (1 - gain) * 0.02 / (value + 0.02))
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

    /// 分離線性亮度 Y 與色度，只改變 Y，再以同一倍率重建 RGB。
    /// 不逐色頻壓縮或裁切，保留廣色域的負通道與 HDR 餘裕。
    static func luminanceGain(_ rgb: SIMD3<Double>, gain: Double, protectsHighlights: Bool) -> Double {
        let y = simd_dot(rgb, SIMD3<Double>(0.2126, 0.7152, 0.0722))
        guard y > 1e-20, protectsHighlights || gain < 1 else { return gain }
        return peak(y, gain: gain) / y
    }

    static func applyLuminance(_ rgb: SIMD3<Double>, gain: Double, protectsHighlights: Bool) -> SIMD3<Double> {
        rgb * luminanceGain(rgb, gain: gain, protectsHighlights: protectsHighlights)
    }

    // Shared syntax supported by both Core Image Kernel Language and Metal.
    // The shoulder joins linear exposure with the same slope, maps white to
    // white, and remains strictly increasing below white. The negative-EV toe
    // approaches unity gain at black and physical exposure in brighter values.
    static let kernel = """
    float protectedExposurePeak(float value, float gain) {
        if (gain == 1.0 || value <= 0.0) { return value; }
        if (gain < 1.0) {
            return value * (gain + (1.0 - gain) * 0.02 / (value + 0.02));
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
