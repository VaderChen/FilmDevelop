import Foundation
import simd

/// Exposure uses linear-sRGB XYZ and CIE Lab with the SAME D65 white on both
/// sides. No D50 profile or gamma-encoded RGB is fed into these equations.
/// Keeping a/b, rather than RGB ratios, avoids amplifying shadow chroma with EV.
/// Matrix and CIE transfer definitions: https://www.w3.org/TR/css-color-4/#color-conversion-code
/// CPU reference and GPU helper stay pointwise, with no extra image buffers.
enum PhotoExposureColor {
    static let luminanceWeights = SIMD3<Double>(0.21263900587151027, 0.7151686787677559, 0.07219231536073371)
    private static let white = SIMD3<Double>(0.9504559270516716, 1, 1.0890577507598784)

    private static func labF(_ t: Double) -> Double {
        t > 216.0/24389 ? cbrt(t) : (24389.0/27*t + 16)/116
    }
    private static func labInverse(_ t: Double) -> Double {
        t > 6.0/29 ? t*t*t : (116*t-16)*27/24389
    }
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let x = simd_dot(rgb, SIMD3(0.41239079926595934, 0.35758433938387796, 0.1804807884018343))
        let y = simd_dot(rgb, luminanceWeights)
        let z = simd_dot(rgb, SIMD3(0.01933081871559185, 0.11919477979462599, 0.9505321522496607))
        let fy = labF(y)
        return SIMD3(116*fy-16, 500*(labF(x/white.x)-fy), 200*(fy-labF(z/white.z)))
    }
    static func replacingLuminance(_ rgb: SIMD3<Double>, scale: Double, ceiling: Double = .infinity) -> SIMD3<Double> {
        guard scale != 1 else { return rgb }
        let y = simd_dot(rgb, luminanceWeights)
        guard y > 1e-20 else { return rgb * scale }
        let targetY = y * scale
        if rgb.x == rgb.y && rgb.y == rgb.z { return SIMD3(repeating: targetY) }
        let color = lab(rgb), fy = labF(targetY)
        let xyz = SIMD3(white.x*labInverse(fy+color.y/500), targetY,
                        white.z*labInverse(fy-color.z/200))
        var result = SIMD3(
            simd_dot(xyz, SIMD3(3.240969941904521, -1.537383177570093, -0.498610760293)),
            simd_dot(xyz, SIMD3(-0.9692436362808796, 1.8759675015077202, 0.04155505740717559)),
            simd_dot(xyz, SIMD3(0.05563007969699366, -0.20397695888897652, 1.0569715142428786)))
        // Compress toward neutral at the same Y instead of clipping individual
        // channels. Existing extended-gamut negative channels remain permitted;
        // HDR has no upper clamp unless a highlight-protection ceiling is supplied.
        let floor = min(0, min(rgb.x, min(rgb.y, rgb.z))) * scale
        let minimum = min(result.x, min(result.y, result.z))
        if minimum < floor {
            let chroma = (targetY-floor)/(targetY-minimum)
            result = SIMD3(repeating: floor) + (result-SIMD3(repeating: minimum))*chroma
        }
        let maximum = max(result.x, max(result.y, result.z))
        if maximum > ceiling {
            let chroma = max(0, (ceiling-targetY)/(maximum-targetY))
            result = SIMD3(repeating: ceiling) - (SIMD3(repeating: maximum)-result)*chroma
        }
        return result
    }

    static let kernel = """
    float exposureLabF(float t) {
        return t > 0.008856451679035631 ? pow(t, 0.3333333333333333) : (903.2962962962963*t+16.0)/116.0;
    }
    float exposureLabInverse(float t) {
        return t > 0.20689655172413793 ? t*t*t : (116.0*t-16.0)/903.2962962962963;
    }
    vec3 exposureLabLuminance(vec3 rgb, float y, float scale, float ceiling) {
        if (scale == 1.0) { return rgb; }
        if (y <= 1.0e-20) { return rgb*scale; }
        float targetY = y*scale;
        if (rgb.r == rgb.g && rgb.g == rgb.b) { return vec3(targetY); }
        float x = dot(rgb, vec3(0.41239079926595934, 0.35758433938387796, 0.1804807884018343));
        float z = dot(rgb, vec3(0.01933081871559185, 0.11919477979462599, 0.9505321522496607));
        float sourceFY = exposureLabF(y);
        float a = exposureLabF(x/0.9504559270516716)-sourceFY;
        float b = sourceFY-exposureLabF(z/1.0890577507598784);
        float targetFY = exposureLabF(targetY);
        vec3 xyz = vec3(0.9504559270516716*exposureLabInverse(targetFY+a), targetY,
                        1.0890577507598784*exposureLabInverse(targetFY-b));
        vec3 result = vec3(
            dot(xyz, vec3(3.240969941904521, -1.537383177570093, -0.498610760293)),
            dot(xyz, vec3(-0.9692436362808796, 1.8759675015077202, 0.04155505740717559)),
            dot(xyz, vec3(0.05563007969699366, -0.20397695888897652, 1.0569715142428786)));
        float lower = min(0.0, min(rgb.r, min(rgb.g, rgb.b)))*scale;
        float minimum = min(result.r, min(result.g, result.b));
        if (minimum < lower) {
            float chroma = (targetY-lower)/(targetY-minimum);
            result = vec3(lower)+(result-vec3(minimum))*chroma;
        }
        float maximum = max(result.r, max(result.g, result.b));
        if (ceiling > 0.0 && maximum > ceiling) {
            float chroma = max(0.0, (ceiling-targetY)/(maximum-targetY));
            result = vec3(ceiling)-(vec3(maximum)-result)*chroma;
        }
        return result;
    }
    """
}
