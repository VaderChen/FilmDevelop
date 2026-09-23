import Foundation
import CoreImage
import simd

/// Independent virtual-scanner model. No proprietary scanner profiles or LUTs.
/// See docs/research/FILM_SCANNING_2026-09-23.md for equations and provenance.
enum PhotoFilmScanner {
    struct Calibration {
        let base: SIMD3<Double>
        let middle: SIMD3<Double>
        let inverse: simd_double3x3
        let slope: Double
    }

    static func signal(_ density: SIMD3<Double>, profile p: PhotoFilmSpectralProfile,
                       light: [Double]) -> SIMD3<Double> {
        var value = SIMD3<Double>.zero
        for k in 0..<13 {
            let optical = p.baseDensity[k] + (p.monochrome ? density.x : simd_dot(p.negativeDyes[k], density))
            value += PhotoFilmSpectralProfile.scanner[k] * light[k] * pow(10, -optical)
        }
        return value
    }

    static func calibration(_ p: PhotoFilmSpectralProfile, light: [Double]) -> Calibration {
        let base = signal(.zero, profile: p, light: light)
        let d = p.density(0), middleDensity = SIMD3<Double>(repeating: d)
        func optical(_ density: SIMD3<Double>) -> SIMD3<Double> {
            let t = signal(density, profile:p, light:light) / base
            return .init((0..<3).map { -log10(max(t[$0], 1e-15)) })
        }
        let middle = optical(middleDensity)
        var jacobian = matrix_identity_double3x3
        if !p.monochrome {
            for c in 0..<3 {
                var plus = middleDensity, minus = middleDensity
                plus[c] += 0.001; minus[c] -= 0.001
                jacobian[c] = (optical(plus) - optical(minus)) / 0.002
            }
        }
        let inverse = abs(simd_determinant(jacobian)) > 1e-8 ? jacobian.inverse : matrix_identity_double3x3
        return Calibration(base:base, middle:middle, inverse:inverse,
                           slope:max(1e-4, (p.density(0.001) - p.density(-0.001)) / 0.002))
    }

    /// FP64 reference for the GPU path; inputs are developed dye densities.
    static func reference(_ density: SIMD3<Double>, profile p: PhotoFilmSpectralProfile,
                          effects e: PhotoFilmEffects) -> SIMD3<Double> {
        let light = PhotoFilmIllumination.spectrum(e.scannerIlluminant, wavelengths: PhotoFilmSpectralProfile.wavelengths)
        let cal = calibration(p, light:light)
        let flare = pow(e.scanFlare / 100, 2) * 0.005
        let contrast = pow(2, (e.printContrast - 50) / 50)
        var rgb: SIMD3<Double>
        if p.reversal {
            if p.monochrome { rgb = .init(repeating: pow(10, -density.x)) }
            else {
                var scan = SIMD3<Double>.zero, white = SIMD3<Double>.zero
                for k in 0..<13 {
                    let sensor = PhotoFilmSpectralProfile.scanner[k] * light[k]
                    scan += sensor * pow(10, -simd_dot(p.negativeDyes[k], density)); white += sensor
                }
                rgb = simd_max(.zero, PhotoFilmSpectralProfile.scannerToRGB * ((scan / white + flare) / (1 + flare)))
            }
            rgb = .init((0..<3).map { 0.18 * pow(max(rgb[$0], 1e-12) / 0.18 * pow(2,e.printExposure), contrast) })
        } else {
            let t = (signal(density, profile:p, light:light) / cal.base + flare) / (1 + flare)
            let logD = SIMD3<Double>((0..<3).map { -log10(max(t[$0], 1e-12)) }) - cal.middle
            let mix = e.scanDensityCorrection / 100
            let delta = logD * (1 - mix) + (cal.inverse * logD) * mix
            rgb = .init((0..<3).map {
                let stops = delta[$0] / cal.slope + e.printExposure
                return 1 / (1 + exp(-max(-40, min(40, log(0.18 / 0.82) + stops * log(2) * contrast))))
            })
        }
        return grade(rgb, effects:e, monochrome:p.monochrome)
    }

    static func grade(_ input: SIMD3<Double>, effects e: PhotoFilmEffects, monochrome: Bool) -> SIMD3<Double> {
        let weights = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        let luma = simd_dot(input, weights)
        if monochrome { return .init(repeating:luma) }
        var rgb = simd_max(.zero, .init(repeating:luma) + (input - .init(repeating:luma)) * (e.scanSaturation / 50))
        func smooth(_ a:Double,_ b:Double,_ x:Double) -> Double { let t=min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t) }
        let middle = smooth(0.02,0.18,luma) * (1-smooth(0.3,0.65,luma))
        let high = smooth(0.25,0.7,luma) * (1-smooth(0.85,1,luma))
        let preset = e.scannerProfile == .warmCool ? 18.0 : 0
        let warmth = ((e.scanMidtoneWarmth + preset) * middle + (e.scanHighlightWarmth - preset) * high) / 100
        rgb *= .init(pow(2,0.35*warmth),pow(2,0.10*warmth),pow(2,-0.4*warmth))
        return rgb * (luma / max(1e-12,simd_dot(rgb,weights)))
    }

    static let metal = """
    float3 scanGrade(float3 rgb, float4 scanTone, float4 scanLook, float mono) {
        float3 w=float3(0.2126,0.7152,0.0722);
        float y=dot(rgb,w);
        if(mono>0.5) return float3(y);
        rgb=max(float3(0),float3(y)+(rgb-y)*scanTone.z);
        float middle=smoothstep(0.02f,0.18f,y)*(1-smoothstep(0.3f,0.65f,y));
        float high=smoothstep(0.25f,0.7f,y)*(1-smoothstep(0.85f,1.0f,y));
        float warmth=scanLook.y*middle+scanLook.z*high;
        rgb*=exp2(float3(0.35,0.10,-0.4)*warmth);
        return rgb*(y/max(1.0e-12f,dot(rgb,w)));
    }
    """
}


/// Display-positive input bypasses negative development and dye separation.
public enum PhotoPositiveScannerProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let kernel: CIKernel? = try? CIKernel.kernels(withMetalString:
        "#include <metal_stdlib>\n#include <CoreImage/CoreImage.h>\nusing namespace metal;\nusing namespace coreimage;\n" + PhotoFilmScanner.metal + """
        [[ stitchable ]] float4 positiveScan(coreimage::sampler input, float4 tone, float4 look) {
            float4 pixel = input.sample(input.coord());
            float alpha = pixel.a;
            float3 rgb = pixel.rgb / max(alpha, 1.0e-6f);
            rgb = (rgb + look.x) / (1.0f + look.x);
            return float4(scanGrade(rgb, tone, look, 0.0f) * alpha, alpha);
        }
        """).first

    static var kernelIsAvailable: Bool { kernel != nil }

    public static func apply(to image: CIImage, effects: PhotoFilmEffects) -> CIImage {
        let e = effects.clamped()
        guard e.scannerProfile != .off, let kernel,
              let linear = image.matchedFromWorkingSpace(to: space) else { return image }
        let preset = e.scannerProfile == .warmCool ? 18.0 : 0
        guard let result = kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [
            linear, CIVector(x: 0, y: 1, z: e.scanSaturation / 50, w: 1),
            CIVector(x: pow(e.scanFlare / 100, 2) * 0.005,
                     y: (e.scanMidtoneWarmth + preset) / 100,
                     z: (e.scanHighlightWarmth - preset) / 100, w: 0)
        ]) else { return image }
        return result.matchedToWorkingSpace(from: space) ?? image
    }
}
