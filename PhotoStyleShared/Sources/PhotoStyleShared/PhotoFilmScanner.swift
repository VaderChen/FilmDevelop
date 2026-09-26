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
                       light: [Double], additionalSilver: Double = 0) -> SIMD3<Double> {
        var value = SIMD3<Double>.zero
        for k in 0..<13 {
            let optical = p.baseDensity[k] + (p.monochrome ? density.x : simd_dot(p.negativeDyes[k], density))
                + additionalSilver * simd_dot(density, .init(0.2126, 0.7152, 0.0722))
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
        let silver = e.silverRetention / 100 * simd_dot(density, .init(0.2126, 0.7152, 0.0722))
        var rgb: SIMD3<Double>
        if p.reversal {
            if p.monochrome { rgb = .init(repeating: pow(10, -(density.x + silver))) }
            else {
                var scan = SIMD3<Double>.zero, white = SIMD3<Double>.zero
                for k in 0..<13 {
                    let sensor = PhotoFilmSpectralProfile.scanner[k] * light[k]
                    scan += sensor * pow(10, -(simd_dot(p.negativeDyes[k], density) + silver)); white += sensor
                }
                rgb = simd_max(.zero, PhotoFilmSpectralProfile.scannerToRGB * ((scan / white + flare) / (1 + flare)))
            }
            rgb = .init((0..<3).map { 0.18 * pow(max(rgb[$0], 1e-12) / 0.18 * pow(2,e.printExposure), contrast) })
        } else {
            let t = (signal(density, profile:p, light:light, additionalSilver:e.silverRetention / 100) / cal.base + flare) / (1 + flare)
            let logD = SIMD3<Double>((0..<3).map { -log10(max(t[$0], 1e-12)) }) - cal.middle
            let mix = e.scanDensityCorrection / 100
            let separated = !p.monochrome && mix > 0
                ? unmix(logD + cal.middle, profile: p, light: light, calibration: cal)
                : cal.inverse * logD
            let delta = logD * (1 - mix) + separated * mix
            rgb = .init((0..<3).map {
                let stops = delta[$0] / cal.slope + e.printExposure
                return 1 / (1 + exp(-max(-40, min(40, log(0.18 / 0.82) + stops * log(2) * contrast))))
            })
        }
        if !p.reversal { rgb = renderIntent(rgb, profile: p) }
        return grade(rgb, effects:e, monochrome:p.monochrome)
    }

    /// 負片掃描的輸出意圖：共用片種反差、紙黑與保留銀設定，
    /// 不關閉掃描、不重跑整套光學印相，也不重複套用使用者曝光／反差。
    /// 無保留銀時維持 18% 灰；彩度沿等亮度 RGB 軸壓回色域。
    static func renderIntent(_ input: SIMD3<Double>, profile p: PhotoFilmSpectralProfile) -> SIMD3<Double> {
        let weights = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        let black = pow(10, -p.printMaxDensity)
        let anchor = (0.18 - black) / (1 - black)
        let bias = log(anchor / (1 - anchor))
        var rgb = SIMD3<Double>((0..<3).map { c in
            let x = min(1, max(0, input[c]))
            if x == 0 { return black }
            if x == 1 { return 1 }
            let z = p.printSlope * (log(x / (1 - x)) - log(0.18 / 0.82)) + bias
            return black + (1 - black) / (1 + exp(-max(-80, min(80, z))))
        })
        let density = SIMD3<Double>((0..<3).map { -log10(max(rgb[$0], 1e-12)) })
        rgb *= pow(10, -p.retainedSilver * simd_dot(density, weights))
        if p.monochrome { return .init(repeating: simd_dot(rgb, weights)) }
        let y = simd_dot(rgb, weights)
        let delta = (rgb - SIMD3<Double>(repeating: y)) * (p.scannerChroma / (1 + 2 * p.retainedSilver))
        var scale = 1.0
        for c in 0..<3 {
            if delta[c] < 0 { scale = min(scale, y / -delta[c]) }
            if delta[c] > 0 { scale = min(scale, (1 - y) / delta[c]) }
        }
        return .init(repeating: y) + delta * max(0, scale)
    }

    /// Reduce chroma along a constant-luminance ray instead of clipping channels.
    /// Preserve HDR luminance; SDR colors remain inside the unit RGB cube.
    static func fitChroma(_ rgb: SIMD3<Double>, luminance y: Double) -> SIMD3<Double> {
        let delta = rgb - SIMD3<Double>(repeating: y)
        let ceiling = max(1, y)
        var scale = 1.0
        for c in 0..<3 {
            if delta[c] < 0 { scale = min(scale, y / -delta[c]) }
            if delta[c] > 0 { scale = min(scale, (ceiling - y) / delta[c]) }
        }
        return .init(repeating: y) + delta * max(0, scale)
    }

    static func grade(_ input: SIMD3<Double>, effects e: PhotoFilmEffects, monochrome: Bool) -> SIMD3<Double> {
        let weights = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        let style = e.scannerProfile.rendering
        let sourceY = max(0, simd_dot(input, weights))
        var luma = sourceY
        if style.y != 1 || style.z != 0 {
            if sourceY > 0 && sourceY < 1 {
                let z = style.y * (log(sourceY / (1 - sourceY)) - log(0.18 / 0.82)) + log(0.18 / 0.82)
                luma = 1 / (1 + exp(-z))
            }
            luma = style.z + (1 - style.z) * luma
        }
        let toned = sourceY > 1e-12 ? input * (luma / sourceY) : .init(repeating: luma)
        if monochrome { return .init(repeating:luma) }
        var rgb = fitChroma(.init(repeating:luma) + (toned - .init(repeating:luma)) * (e.scanSaturation / 50 * style.x), luminance: luma)
        func smooth(_ a:Double,_ b:Double,_ x:Double) -> Double { let t=min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t) }
        let middle = smooth(0.02,0.18,luma) * (1-smooth(0.3,0.65,luma))
        let high = smooth(0.25,0.7,luma) * (1-smooth(0.85,1,luma))
        let preset = e.scannerProfile.warmth
        let warmth = ((e.scanMidtoneWarmth + preset.x) * middle + (e.scanHighlightWarmth + preset.y) * high) / 100
        rgb *= .init(pow(2,0.35*warmth),pow(2,0.10*warmth),pow(2,-0.4*warmth))
        return fitChroma(rgb * (luma / max(1e-12,simd_dot(rgb,weights))), luminance: luma)
    }

    static let metal = """
    float3 scanRenderIntent(float3 rgb, float4 paper, float chroma, float mono) {
        float3 w=float3(0.2126,0.7152,0.0722);
        float black=pow(10.0f,-paper.y);
        float anchor=(0.18f-black)/(1.0f-black);
        float bias=log(anchor/(1.0f-anchor));
        float3 x=clamp(rgb,float3(1e-12f),float3(1.0f-1e-7f));
        float3 z=paper.x*(log(x/(1.0f-x))-log(0.18f/0.82f))+bias;
        float3 tone=black+(1.0f-black)/(1.0f+exp(-clamp(z,float3(-80),float3(80))));
        tone=select(tone,float3(black),rgb<=0.0f);
        tone=select(tone,float3(1.0f),rgb>=1.0f);
        float silver=paper.w*dot(-log10(max(tone,float3(1e-12f))),w);
        tone*=pow(10.0f,-silver);
        float y=dot(tone,w);
        if(mono>0.5f) return float3(y);
        float3 delta=(tone-y)*(chroma/(1.0f+2.0f*paper.w));
        float scale=1.0f;
        for(int c=0;c<3;++c) {
            if(delta[c]<0.0f) scale=min(scale,y/-delta[c]);
            if(delta[c]>0.0f) scale=min(scale,(1.0f-y)/delta[c]);
        }
        return float3(y)+delta*max(0.0f,scale);
    }
    float3 scanFitChroma(float3 rgb, float y) {
        float3 delta=rgb-y;
        float ceiling=max(1.0f,y), scale=1.0f;
        for(int c=0;c<3;++c) {
            if(delta[c]<0) scale=min(scale,y/-delta[c]);
            if(delta[c]>0) scale=min(scale,(ceiling-y)/delta[c]);
        }
        return float3(y)+delta*max(0.0f,scale);
    }
    float3 scanGrade(float3 rgb, float4 scanTone, float4 scanLook, float4 style, float mono) {
        float3 w=float3(0.2126,0.7152,0.0722);
        float sourceY=max(0.0f,dot(rgb,w)), y=sourceY;
        if(style.y!=1.0f || style.z!=0.0f) {
            if(sourceY>0.0f && sourceY<1.0f) {
                float z=style.y*(log(sourceY/(1-sourceY))-log(0.18f/0.82f))+log(0.18f/0.82f);
                y=1/(1+exp(-z));
            }
            y=style.z+(1-style.z)*y;
        }
        rgb=sourceY>1e-12f ? rgb*(y/sourceY) : float3(y);
        if(mono>0.5) return float3(y);
        rgb=scanFitChroma(float3(y)+(rgb-y)*scanTone.z*style.x,y);
        float middle=smoothstep(0.02f,0.18f,y)*(1-smoothstep(0.3f,0.65f,y));
        float high=smoothstep(0.25f,0.7f,y)*(1-smoothstep(0.85f,1.0f,y));
        float warmth=scanLook.y*middle+scanLook.z*high;
        rgb*=exp2(float3(0.35,0.10,-0.4)*warmth);
        return scanFitChroma(rgb*(y/max(1.0e-12f,dot(rgb,w))),y);
    }
    """
}


/// Display-positive input bypasses negative development and dye separation.
public enum PhotoPositiveScannerProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let kernel: CIKernel? = try? CIKernel.kernels(withMetalString:
        "#include <metal_stdlib>\n#include <CoreImage/CoreImage.h>\nusing namespace metal;\nusing namespace coreimage;\n" + PhotoFilmScanner.metal + """
        [[ stitchable ]] float4 positiveScan(coreimage::sampler input, float4 tone, float4 look, float4 style) {
            float4 pixel = input.sample(input.coord());
            float alpha = pixel.a;
            float3 rgb = pixel.rgb / max(alpha, 1.0e-6f);
            rgb = (rgb + look.x) / (1.0f + look.x);
            return float4(scanGrade(rgb, tone, look, style, 0.0f) * alpha, alpha);
        }
        """).first

    static var kernelIsAvailable: Bool { kernel != nil }

    public static func apply(to image: CIImage, effects: PhotoFilmEffects) -> CIImage {
        let e = effects.clamped()
        guard e.scannerProfile != .off, let kernel,
              let linear = image.matchedFromWorkingSpace(to: space) else { return image }
        let preset = e.scannerProfile.warmth
        let style = e.scannerProfile.rendering
        guard let result = kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [
            linear, CIVector(x: 0, y: 1, z: e.scanSaturation / 50, w: 1),
            CIVector(x: pow(e.scanFlare / 100, 2) * 0.005,
                     y: (e.scanMidtoneWarmth + preset.x) / 100,
                     z: (e.scanHighlightWarmth + preset.y) / 100, w: 0),
            CIVector(x:style.x,y:style.y,z:style.z,w:style.w)
        ]) else { return image }
        return result.matchedToWorkingSpace(from: space) ?? image
    }
}
