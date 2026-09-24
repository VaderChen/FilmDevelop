import CoreGraphics
import CoreImage
import Foundation

/// FP32, 13-band negative/print/view simulation. RGB is explicitly matched to
/// extended linear sRGB on entry and back to the caller's working space on exit.
/// The original radiance basis and calibrated virtual scanner are documented in
/// PhotoFilmSpectralProfile; this is not measured stock or CIE spectral recovery.
public enum PhotoFilmSpectralProcessor {
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public static func apply(
        to image: CIImage,
        stock: PhotoFilmStock,
        effects: PhotoFilmEffects = .neutral,
        strength: Double = 1
    ) -> CIImage {
        guard let kernel = compiled.kernel,
              let index = PhotoFilmStock.allCases.firstIndex(of: stock),
              let linear = image.matchedFromWorkingSpace(to: linearSRGB) else { return image }
        let e = effects.clamped()
        let amount = strength.isFinite ? min(1, max(0, strength)) : 0
        let filterIndex = PhotoFilmEffects.MonochromeFilter.allCases.firstIndex(of: e.monochromeFilter) ?? 0
        let profile = PhotoFilmSpectralProfile.all[index]
        let light = PhotoFilmIllumination.spectrum(e.scannerIlluminant, wavelengths: PhotoFilmSpectralProfile.wavelengths)
        let calibration = PhotoFilmScanner.calibration(profile, light:light)
        func vector(_ value: SIMD3<Double>) -> CIVector { CIVector(x:value.x,y:value.y,z:value.z) }
        let scanRows = (0..<3).map { r in vector(.init(calibration.inverse.columns.0[r], calibration.inverse.columns.1[r], calibration.inverse.columns.2[r])) }
        let warmth = e.scannerProfile == .warmCool ? 18.0 : 0
        guard let result = kernel.apply(extent: image.extent, roiCallback: { input, rect in
            input == 0 ? rect : PhotoFilmSpectralReconstruction.extent
        }, arguments: [
            linear] + PhotoFilmSpectralReconstruction.planes + [Double(index),
            CIVector(x: Double(PhotoFilmEffects.Illuminant.allCases.firstIndex(of: e.printIlluminant)!),
                     y: Double(PhotoFilmEffects.Illuminant.allCases.firstIndex(of: e.viewIlluminant)!)),
            CIVector(x: e.printExposure, y: pow(2, (e.printContrast - 50) / 50),
                     z: e.monochromeFilterStrength / 100 * amount, w: Double(filterIndex)),
            CIVector(x:e.scannerProfile == .off ? 0 : 1,
                     y:Double(PhotoFilmEffects.Illuminant.allCases.firstIndex(of:e.scannerIlluminant)!),
                     z:calibration.slope, w:pow(e.scanFlare / 100, 2) * 0.005),
            CIVector(x:0, y:1, z:e.scanSaturation/50, w:e.scanDensityCorrection/100),
            CIVector(x:0, y:(e.scanMidtoneWarmth + warmth)/100, z:(e.scanHighlightWarmth - warmth)/100, w:0),
            vector(calibration.base), vector(calibration.middle), scanRows[0], scanRows[1], scanRows[2]
        ]) else { return image }
        var output = (result.matchedToWorkingSpace(from: linearSRGB) ?? image).cropped(to: image.extent)
        // 掃描／正片略過光學負片印相，改在成品套用光源色彩補償。
        // 只補光源，不重複套用已在 kernel 計算的曝光、反差或掃描設定。
        if (e.scannerProfile != .off || stock.family == "reversal"), e.printIlluminant != .reference {
            var lighting = PhotoFilmEffects.neutral
            lighting.printIlluminant = e.printIlluminant
            output = PhotoFilmEffectsProcessor.applyPrint(to: output, effects: lighting)
            if stock.isMonochrome {
                output = PhotoImageEffectsProcessor.monochrome(output, profile: .desaturate)
            }
        }
        return output
    }

    static var kernelIsAvailable: Bool { compiled.kernel != nil }
    static var kernelCompilationError: String? { compiled.error }

    /// Bake immutable profile constants once, not once per image or per slider.
    /// The GPU still integrates spectral transmission at runtime: nonlinear
    /// Beer-Lambert and print curves prevent collapse into a single RGB matrix.
    private static let compiled: (kernel: CIKernel?, error: String?) = {
        func f(_ value: Double) -> String {
            String(format: "%.10ef", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        func v3(_ v: SIMD3<Double>) -> String { "float3(\(f(v.x)),\(f(v.y)),\(f(v.z)))" }
        func v4(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> String {
            "float4(\(f(x)),\(f(y)),\(f(z)),\(f(w)))"
        }
        func array(_ type: String, _ name: String, _ values: [String]) -> String {
            "constant \(type) \(name)[\(values.count)] = {\(values.joined(separator: ","))};\n"
        }
        let profiles = PhotoFilmSpectralProfile.all
        let scannerMatrix = PhotoFilmSpectralProfile.scannerToRGB
        let scanRows = (0..<3).map { r in
            SIMD3<Double>(scannerMatrix.columns.0[r], scannerMatrix.columns.1[r], scannerMatrix.columns.2[r])
        }
        var tables = array("float3", "spScanner", PhotoFilmSpectralProfile.scanner.map(v3))
        tables += array("float3", "spScanRows", scanRows.map(v3))
        tables += array("float3", "spSensitivity", profiles.flatMap(\.sensitivity).map(v3))
        tables += array("float3", "spNegativeDyes", profiles.flatMap(\.negativeDyes).map(v3))
        tables += array("float3", "spPrintSensitivity", profiles.flatMap(\.printSensitivity).map(v3))
        tables += array("float3", "spPrintDyes", profiles.flatMap(\.printDyes).map(v3))
        tables += array("float", "spBase", profiles.flatMap(\.baseDensity).map(f))
        tables += array("float4", "spCurve", profiles.map { v4($0.toe, $0.shoulder, $0.bend, $0.maxDensity) })
        tables += array("float4", "spPaper", profiles.map { v4($0.printSlope, $0.printMaxDensity, $0.printBias, $0.retainedSilver) })
        tables += array("float", "spScanChroma", profiles.map { f($0.scannerChroma) })
        tables += array("float4", "spMode", profiles.map { v4($0.monochrome ? 1 : 0, $0.reversal ? 1 : 0, $0.reversalShift, 0) })
        tables += array("float3", "spGain", profiles.map { v3($0.layerGain) })
        tables += array("float3", "spEV", profiles.map { v3($0.layerEV) })
        tables += array("float3", "spPrintReference", profiles.map { v3($0.referencePrintExposure) })
        tables += array("float", "spFilters", PhotoFilmEffects.MonochromeFilter.allCases.flatMap { filter in
            PhotoFilmSpectralProfile.wavelengths.map { f(PhotoFilmSpectralProfile.filterTransmission(filter, wavelength: $0)) }
        })
        tables += array("float", "spLights", PhotoFilmEffects.Illuminant.allCases.flatMap {
            PhotoFilmIllumination.spectrum($0, wavelengths: PhotoFilmSpectralProfile.wavelengths).map(f)
        })
        let source = """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;
        \(tables)
        \(PhotoFilmScanner.metal)
        float3 spOutputTone(float3 rgb, float4 controls) {
            return 0.18f * pow(max(rgb, float3(0)) / 0.18f, float3(controls.y)) * exp2(controls.x);
        }
        float3 spSoftplus(float3 v) {
            return max(v, float3(0.0)) + log(1.0 + exp(-abs(v)));
        }
        float3 spDensity(float3 ev, float4 curve) {
            return curve.w * (spSoftplus(curve.z * (ev - curve.x)) - spSoftplus(curve.z * (ev - curve.y)))
                / (curve.z * (curve.y - curve.x));
        }
        // Hardware texture interpolation has limited fractional precision.
        // Four exact texel centres + float arithmetic keep the 12-bit budget.
        float4 spLookup(coreimage::sampler table, float2 point) {
            float2 p=floor(point-0.5f)+0.5f, f=point-p;
            return mix(mix(table.sample(table.transform(p)),table.sample(table.transform(p+float2(1,0))),f.x),
                       mix(table.sample(table.transform(p+float2(0,1))),table.sample(table.transform(p+float2(1,1))),f.x),f.y);
        }
        [[ stitchable ]] float4 filmSpectral(coreimage::sampler input,
            coreimage::sampler table0, coreimage::sampler table1, coreimage::sampler table2, coreimage::sampler table3, coreimage::sampler table4,
            float stockIndex, float2 lights, float4 controls,
            float4 scanSettings, float4 scanTone, float4 scanLook,
            float3 scanBase, float3 scanMiddle, float3 scanRow0, float3 scanRow1, float3 scanRow2, destination dest) {
            float4 image = input.sample(input.transform(dest.coord()));
            float alpha = isfinite(image.a) ? clamp(image.a, 0.0, 1.0) : 0.0;
            if (alpha <= 0.0) { return float4(0.0); }
            float3 rgb = image.rgb / alpha;
            rgb = select(float3(0.0), rgb, isfinite(rgb));
            rgb = clamp(rgb, float3(0.0), float3(65536.0));
            // Normalize by max channel: colour shape uses LHTSS; intensity is
            // never quantized into a LUT axis, including HDR and 12-bit ramps.
            float amplitude = max(rgb.x, max(rgb.y, rgb.z));
            int face = rgb.x >= rgb.y && rgb.x >= rgb.z ? 0 : (rgb.y >= rgb.z ? 1 : 2);
            float2 uv = amplitude > 0.0 ? float2(rgb[(face+1)%3],rgb[(face+2)%3])/amplitude : float2(0.0);
            float n = \(PhotoFilmSpectralReconstruction.dimension).0f;
            float2 coord = float2(0.5f, float(face)*n+0.5f) + uv*(n-1.0f);
            float4 bands0 = spLookup(table0,coord)*amplitude;
            float4 bands1 = spLookup(table1,coord)*amplitude;
            float4 bands2 = spLookup(table2,coord)*amplitude;
            float4 bands3 = spLookup(table3,coord)*amplitude;
            float4 bands4 = spLookup(table4,coord)*amplitude;
            int stock = clamp(int(stockIndex), 0, \(PhotoFilmStock.allCases.count - 1));
            int base = stock * 13;
            float4 mode = spMode[stock];
            float4 curve = spCurve[stock];
            float4 paper = spPaper[stock];
            int printLight = clamp(int(lights.x), 0, \(PhotoFilmEffects.Illuminant.allCases.count - 1)) * 13;
            int viewLight = clamp(int(lights.y), 0, \(PhotoFilmEffects.Illuminant.allCases.count - 1)) * 13;
            int filterBase = clamp(int(controls.w), 0, 4) * 13;
            float3 h = float3(0.0), norm = float3(0.0);
            for (int k = 0; k < 13; ++k) {
                float transmission = mode.x > 0.5 ? mix(1.0, spFilters[filterBase + k], controls.z) : 1.0;
                float3 sensitivity = spSensitivity[base + k] * transmission;
                float radiance = k < 3 ? bands0[k] : (k < 6 ? bands1[k-3] : (k < 9 ? bands2[k-6] : (k < 12 ? bands3[k-9] : bands4.x)));
                h += radiance * sensitivity;
                norm += sensitivity;
            }
            h /= norm;
            float3 ev = log2(max(h, float3(1.0e-7)) / 0.18) * spGain[stock] + spEV[stock];
            float3 density = spDensity(ev + mode.z, curve);
            if (scanSettings.x > 0.5) {
                int scanLight=clamp(int(scanSettings.y),0,\(PhotoFilmEffects.Illuminant.allCases.count - 1))*13;
                float3 measured=float3(0), white=float3(0);
                float3 material=mode.y>0.5 ? curve.w-density : density;
                for(int k=0;k<13;++k) {
                    float optical=(mode.y>0.5 ? 0.0f : spBase[base+k])
                        +(mode.x>0.5 ? material.x : dot(spNegativeDyes[base+k],material));
                    float3 sensor=spScanner[k]*spLights[scanLight+k];
                    measured+=sensor*exp(-2.302585092994046f*optical);
                    white+=sensor;
                }
                float3 positive;
                if(mode.y>0.5) {
                    float3 t=(measured/white+scanSettings.w)/(1+scanSettings.w);
                    positive=mode.x>0.5 ? float3(t.x) : max(float3(0),float3(dot(t,spScanRows[0]),dot(t,spScanRows[1]),dot(t,spScanRows[2])));
                    positive=0.18f*pow(max(positive,float3(1e-12f))/0.18f*exp2(scanTone.x),float3(scanTone.y));
                } else {
                    float3 t=(measured/scanBase+scanSettings.w)/(1+scanSettings.w);
                    float3 logD=-log10(max(t,float3(1e-12f)))-scanMiddle;
                    float3 unmixed=float3(dot(logD,scanRow0),dot(logD,scanRow1),dot(logD,scanRow2));
                    float3 stops=mix(logD,unmixed,scanTone.w)/scanSettings.z+scanTone.x;
                    positive=1/(1+exp(-clamp(-1.516347489f+stops*0.693147181f*scanTone.y,float3(-40),float3(40))));
                    positive=scanRenderIntent(positive,paper,spScanChroma[stock],mode.x);
                }
                return float4(spOutputTone(scanGrade(positive,scanTone,scanLook,mode.x),controls)*alpha,alpha);
            }
            if (mode.y > 0.5) {
                // Positive reversal film goes straight to viewing, no fictitious
                // second negative. Contrast pivots around 18% transmission.
                float anchor = 0.744727494896694;
                density = max(float3(0.0), anchor + (curve.w - density - anchor));
            } else {
                float3 printH = float3(0.0);
                for (int k = 0; k < 13; ++k) {
                    float optical = spBase[base + k] + (mode.x > 0.5 ? density.x : dot(spNegativeDyes[base + k], density));
                    printH += spPrintSensitivity[base + k] * spLights[printLight + k] * exp(-2.302585092994046 * optical);
                }
                // Develop the print baseline before the shared output controls.
                float3 printEV = log2(max(printH / spPrintReference[stock], float3(1.0e-12)));
                density = paper.y / (1.0 + exp(-(printEV * paper.x + paper.z)));
                density += paper.w * dot(density, float3(0.2126, 0.7152, 0.0722));
            }
            if (mode.x > 0.5) {
                float silverTransmission = exp(-2.302585092994046 * density.x);
                return float4(spOutputTone(float3(silverTransmission),controls) * alpha, alpha);
            }
            float3 scan = float3(0.0);
            for (int k = 0; k < 13; ++k) {
                float3 dyes = mode.y > 0.5 ? spNegativeDyes[base + k] : spPrintDyes[base + k];
                scan += spScanner[k] * spLights[viewLight + k] * exp(-2.302585092994046 * dot(dyes, density));
            }
            float3 result = float3(dot(scan, spScanRows[0]), dot(scan, spScanRows[1]), dot(scan, spScanRows[2]));
            result = max(result, float3(0.0));
            return float4(spOutputTone(result,controls) * alpha, alpha);
        }
        """
        do {
            let kernel = try CIKernel.kernels(withMetalString: source)
                .first(where: { $0.name == "filmSpectral" })
            return (kernel, kernel == nil ? "filmSpectral kernel missing" : nil)
        } catch {
            return (nil, String(describing: error))
        }
    }()
}
