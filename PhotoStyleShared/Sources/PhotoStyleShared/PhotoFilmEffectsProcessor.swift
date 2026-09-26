import CoreGraphics
import CoreImage
import Foundation
import Metal
import simd

/// Neutral optical bloom and monochrome filtering. Emulsion grain and substrate
/// return are handled before development by PhotoFilmExposureProcessor.
public enum PhotoFilmEffectsProcessor {
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Extract light before RAW display companding. Matching explicitly around
    /// this branch keeps its threshold in linear light for both the app's linear
    /// context and the shared renderer's sRGB context.
    public static func applyLightScatter(
        to image: CIImage,
        effects: PhotoFilmEffects,
        strength: Double = 1
    ) -> CIImage {
        let effects = effects.clamped()
        let image = PhotoFilmMaterialProcessor.emulsion(to: image, effects: effects, strength: strength)
        let strength = unit(strength)
        let bloom = PhotoFilmEffects.effectAmount(effects.bloomAmount) * strength
        guard bloom > 0,
              let linear = image.matchedFromWorkingSpace(to: linearSRGB) else { return image }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge.isFinite, longEdge > 0 else { return image }

        func energy(threshold: Double) -> CIImage? {
            kernels.extract?.apply(extent: extent, arguments: [linear, PhotoFilmEffects.linearLightThreshold(threshold)])
        }
        guard let bloomEnergy = energy(threshold: effects.bloomThreshold) else { return image }
        func spread(_ energy: CIImage, radius: Double) -> CIImage {
            energy.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: longEdge * radius / 100])
                .cropped(to: extent)
        }
        guard let scattered = kernels.scatter?.apply(extent: extent, arguments: [
            linear,
            bloomEnergy, spread(bloomEnergy, radius: effects.bloomRadius),
            bloom
        ]) else { return image }
        return (scattered.matchedToWorkingSpace(from: linearSRGB) ?? image).cropped(to: extent)
    }

    /// A digital approximation of a colored filter in front of panchromatic
    /// film. Normalized channel sensitivities preserve neutral objects. Call
    /// before the selected monochrome tone signature, while RGB is available.
    public static func applyMonochromeFilter(
        to image: CIImage,
        effects: PhotoFilmEffects,
        strength: Double = 1
    ) -> CIImage {
        let effects = effects.clamped()
        let amount = effects.monochromeFilterStrength / 100 * unit(strength)
        guard effects.monochromeFilter != .none, amount > 0 else { return image }
        let filteredWeights: (Double, Double, Double)
        switch effects.monochromeFilter {
        case .none: return image
        case .yellow: filteredWeights = (0.34, 0.63, 0.03)
        case .orange: filteredWeights = (0.58, 0.40, 0.02)
        case .red: filteredWeights = (0.82, 0.17, 0.01)
        case .green: filteredWeights = (0.12, 0.84, 0.04)
        }
        let neutral = (0.2126, 0.7152, 0.0722)
        let weights = CIVector(
            x: neutral.0 + (filteredWeights.0 - neutral.0) * amount,
            y: neutral.1 + (filteredWeights.1 - neutral.1) * amount,
            z: neutral.2 + (filteredWeights.2 - neutral.2) * amount,
            w: 0
        )
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights,
            "inputGVector": weights,
            "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// Compatibility entry point for standalone clients. Routes to polygon
    /// emulsion capture; no separate correlated-noise renderer is retained.
    public static func applyStructuredGrain(
        to image: CIImage,
        masks: PhotoToneMasks,
        highlightAmount: Double,
        midtoneAmount: Double,
        shadowAmount: Double,
        profile: PhotoGrainProfile,
        effects: PhotoFilmEffects,
        monochrome: Bool,
        seed: UInt32 = 0
    ) -> CIImage {
        PhotoEmulsionExposureProcessor.apply(to: image, effects: effects,
            amounts: .init(highlights: highlightAmount, midtones: midtoneAmount, shadows: shadowAmount),
            monochrome: monochrome, seed: seed)
    }

    /// 曝光補償先於乳劑、顯影與底片色彩。線性 sRGB → XYZ → Lab (D65)，
    /// 依曝光／保護曲線更新 L，保留 a/b 後重建 RGB，避免同步放大暗部色度。
    public static func applyExposure(to image: CIImage, effects: PhotoFilmEffects,
                                     strength: Double = 1) -> CIImage {
        let e = effects.clamped()
        let amount = unit(strength)
        let ev = e.resolvedPrintExposure
        guard ev != .zero, amount > 0,
              let linear = image.matchedFromWorkingSpace(to: linearSRGB),
              let result = kernels.exposure?.apply(extent: image.extent, arguments: [
                linear, CIVector(x: ev.x, y: ev.y, z: ev.z), e.highlightProtectionEnabled ? 1.0 : 0.0, amount
              ]) else { return image }
        return (result.matchedToWorkingSpace(from: linearSRGB) ?? image).cropped(to: image.extent)
    }

    /// 一般風格的中性數位印相：負片印相光源反向補償，觀看光源正向投射。
    /// 共用底片的 13 波段光源與虛擬掃描器，但不套用任何特定底片的感光曲線。
    public static func applyPrint(
        to image: CIImage,
        effects: PhotoFilmEffects,
        strength: Double = 1
    ) -> CIImage {
        var e = effects.clamped()
        let image = applyExposure(to: image, effects: e, strength: strength)
        e.clearPrintExposure()
        let amount = unit(strength)
        guard amount > 0,
              e.printContrast != 50 ||
                e.printIlluminant != .reference || e.viewIlluminant != .reference,
              let linear = image.matchedFromWorkingSpace(to: linearSRGB) else { return image }
        let printMatrix = illuminantMatrices[e.printIlluminant]!.inverse
        let viewMatrix = illuminantMatrices[e.viewIlluminant]!
        func rows(_ matrix: simd_double3x3) -> [CIVector] {
            (0..<3).map { row in
                CIVector(x: matrix.columns.0[row], y: matrix.columns.1[row], z: matrix.columns.2[row])
            }
        }
        guard let result = kernels.print?.apply(extent: image.extent, arguments:
            [linear] + rows(printMatrix) + rows(viewMatrix) +
            [CIVector(x: pow(2, e.printExposure), y: pow(2, (e.printContrast - 50) / 50), z: amount, w: e.highlightProtectionEnabled ? 1 : 0)]
        ) else { return image }
        return (result.matchedToWorkingSpace(from: linearSRGB) ?? image).cropped(to: image.extent)
    }

    private static let illuminantMatrices: [PhotoFilmEffects.Illuminant: simd_double3x3] =
        Dictionary(uniqueKeysWithValues: PhotoFilmEffects.Illuminant.allCases.map { light in
            // 參考光源直接使用單位矩陣，避免中性處理的往返誤差。
            guard light != .reference else { return (light, matrix_identity_double3x3) }
            let spectrum = PhotoFilmIllumination.spectrum(light, wavelengths: PhotoFilmSpectralProfile.wavelengths)
            var response = simd_double3x3(columns: (.zero, .zero, .zero))
            for index in spectrum.indices {
                let scanner = PhotoFilmSpectralProfile.scanner[index] * spectrum[index]
                let basis = PhotoFilmSpectralProfile.inputBasis[index]
                response.columns.0 += scanner * basis.x
                response.columns.1 += scanner * basis.y
                response.columns.2 += scanner * basis.z
            }
            return (light, PhotoFilmSpectralProfile.scannerToRGB * response)
        })

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private struct FilmKernels: @unchecked Sendable {
        let extract: CIColorKernel?
        let scatter: CIColorKernel?
        let print: CIColorKernel?
        let exposure: CIColorKernel?
    }

    private static let kernels: FilmKernels = {
        func make(_ name: String, parameters: String, body: String, destination: Bool = false, helpers: String = "") -> CIColorKernel? {
            PhotoGPUColorKernel.make(name, parameters: parameters, body: body, destination: destination, helpers: helpers)
        }
        let extract = make("filmExtractLight", parameters: "__sample image, float threshold", body: """
            vec3 rgb = image.rgb / max(image.a, 0.000001);
            float luminance = dot(max(rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
            float energy = max(luminance - threshold, 0.0) * image.a;
            return vec4(energy, energy, energy, 1.0);
            """)
        let scatter = make("filmScatterLight", parameters: "__sample image, __sample bloomEnergy, __sample bloomSpread, float bloom", body: """
            // Positive local spread leaves a flat field unchanged and adds no
            // highlight brightness where the source already contains energy.
            float bloomRing = max(bloomSpread.r - bloomEnergy.r - 0.000001, 0.0);
            vec3 glow = vec3(bloomRing * bloom);
            return vec4(image.rgb + glow * image.a, image.a);
            """)
        let exposure = make("filmLuminanceExposure", parameters: "__sample image, vec3 ev, float protection, float amount", body: """
            if (image.a <= 0.0) { return vec4(0.0); }
            vec3 rgb = image.rgb / image.a;
            // Compute EV in linear Y, then change Lab L while retaining a/b.
            float y = dot(rgb, vec3(0.21263900587151027, 0.7151686787677559, 0.07219231536073371));
            float gain = exp2(zoneExposureEV(y, ev));
            float scale = gain;
            if (y > 1.0e-20 && (protection > 0.5 && gain > 1.0)) {
                scale = protectedExposurePeak(y, gain) / y;
            }
            float ceiling = protection > 0.5 && gain > 1.0 ? max(1.0, max(rgb.r, max(rgb.g, rgb.b))) : 0.0;
            return vec4(exposureLabLuminance(rgb, y, mix(1.0, scale, amount), ceiling) * image.a, image.a);
            """, helpers: PhotoExposureProtection.kernel + PhotoExposureProtection.zoneKernel + PhotoExposureColor.kernel)
        let print = make("filmPrint", parameters: "__sample image, vec3 printR, vec3 printG, vec3 printB, vec3 viewR, vec3 viewG, vec3 viewB, vec4 controls", body: """
            if (image.a <= 0.0) { return vec4(0.0); }
            vec3 source = image.rgb / image.a;
            vec3 rgb = vec3(dot(source, printR), dot(source, printG), dot(source, printB));
            // 反差以線性 18% 灰為中心；保留負通道與 HDR，不裁切到 SDR。
            rgb = sign(rgb) * 0.18 * pow(abs(rgb) / 0.18, vec3(controls.y));
            rgb = vec3(dot(rgb, viewR), dot(rgb, viewG), dot(rgb, viewB));
            return vec4(mix(source, rgb, controls.z) * image.a, image.a);
            """, helpers: PhotoExposureProtection.kernel)
        return FilmKernels(extract: extract, scatter: scatter, print: print, exposure: exposure)
    }()
}
