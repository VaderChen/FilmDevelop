import CoreGraphics
import CoreImage
import Foundation
import Metal

/// A bounded, three-layer reaction/diffusion study, written independently of
/// Filmulator. Chemistry is evaluated in extended linear sRGB; inputs and
/// outputs retain the caller's working space. This is an artistic development
/// model, not a calibration of a particular emulsion or developer.
///
/// Each layer consumes its remaining silver salt to grow developed crystal
/// volume. All three layers share a finite developer pool; only that pool is
/// diffused and replenished. No blur or sharpening is applied to image pixels.
/// Relative growth against an isolated, uniform layer is mapped back to exposure
/// so a neutral flat field keeps its tone and the subsequent stock curve remains
/// responsible for sensitometry. The simulation uses FP32 kernels throughout.
public enum PhotoFilmDevelopmentProcessor {
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let defaultStepCount = 12
    private static let maximumFieldLongEdge: CGFloat = 768

    public static func apply(
        to image: CIImage,
        effects: PhotoFilmEffects,
        strength: Double = 1
    ) -> CIImage {
        apply(to: image, effects: effects, strength: strength, stepCount: defaultStepCount)
    }

    /// Internal step-count override is used to check numerical convergence.
    /// Production always uses twelve bounded steps and a capped spatial field.
    static func apply(
        to image: CIImage,
        effects: PhotoFilmEffects,
        strength: Double,
        stepCount: Int
    ) -> CIImage {
        let effects = effects.clamped()
        let amount = PhotoFilmEffects.effectAmount(effects.developmentAmount) * unit(strength)
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard amount > 0, extent.width > 0, extent.height > 0,
              extent.minX.isFinite, extent.minY.isFinite, longEdge.isFinite,
              let activation = kernels.activation,
              let saltStep = kernels.saltStep,
              let developerStep = kernels.developerStep,
              let replenish = kernels.replenish,
              let diffusion = kernels.diffusion,
              let relativeGrowth = kernels.relativeGrowth,
              let composite = kernels.composite,
              let linear = image.matchedFromWorkingSpace(to: linearSRGB) else { return image }

        let steps = min(48, max(4, stepCount))
        let time = 0.4 + 2.6 * effects.developmentTime / 100
        let dt = time / Double(steps)
        let reaction = 1.6 * dt
        let replenishment = 1 - exp(-2.5 * effects.developmentAgitation / 100 * dt)
        let scale = min(1, maximumFieldLongEdge / longEdge)
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let local = linear.transformed(by: origin)
        let fieldExtent = CGRect(x: 0, y: 0, width: extent.width * scale, height: extent.height * scale)
        let reduced: CIImage
        if scale < 1 {
            reduced = local.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1
            ]).cropped(to: fieldExtent)
        } else {
            reduced = local
        }
        guard let active = activation.apply(extent: fieldExtent, arguments: [reduced]) else { return image }
        let one = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: fieldExtent)
        var salt = one
        var developer = one
        // Diffusion distance is in percent of the full-frame long edge at unit
        // time. Heat-equation variances add: each substep has sigma = distance√dt.
        let sigma = Double(longEdge * scale) * effects.developmentDiffusion / 100 * sqrt(dt)
        let diffusionRadius = min(24, max(4, ceil(4 * sigma + 4)))
        let weights = diffusionWeights(variance: sigma * sigma, radius: Int(diffusionRadius))
        let stencilArguments: [Any] = weights + [diffusionRadius]
        for _ in 0..<steps {
            guard let nextSalt = saltStep.apply(extent: fieldExtent, arguments: [active, salt, developer, reaction]),
                  let consumed = developerStep.apply(extent: fieldExtent, arguments: [active, salt, developer, reaction])
            else { return image }
            let roi: CIKernelROICallback = { _, rect in rect.insetBy(dx: -diffusionRadius, dy: -diffusionRadius) }
            guard let horizontal = diffusion.apply(extent: fieldExtent, roiCallback: roi, arguments: [
                consumed.clampedToExtent(), CIVector(x: 1, y: 0)
            ] + stencilArguments), let diffused = diffusion.apply(extent: fieldExtent, roiCallback: roi, arguments: [
                horizontal.clampedToExtent(), CIVector(x: 0, y: 1)
            ] + stencilArguments) else { return image }
            guard let supplied = replenish.apply(extent: fieldExtent, arguments: [diffused, replenishment]) else { return image }
            salt = nextSalt
            developer = supplied
        }
        guard let ratio = relativeGrowth.apply(extent: fieldExtent, arguments: [
            active, salt, reaction, replenishment, Double(steps), amount
        ]) else { return image }
        // The correction field, never the source photograph, is interpolated.
        // Clamping before upsampling prevents a dark border at the frame edge.
        let fullRatio = ratio.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        guard let developed = composite.apply(extent: extent, arguments: [linear, fullRatio]) else { return image }
        return (developed.matchedToWorkingSpace(from: linearSRGB) ?? image).cropped(to: extent)
    }

    static var kernelsAreAvailable: Bool {
        kernels.activation != nil && kernels.saltStep != nil && kernels.developerStep != nil
            && kernels.replenish != nil && kernels.diffusion != nil && kernels.relativeGrowth != nil && kernels.composite != nil
    }

    /// Exact infinite-grid heat kernel: w[n] = exp(-v) I_n(v), where v is
    /// the desired variance and I_n is the modified Bessel function. Positive
    /// weights preserve nonnegative concentrations. Unlike sampling a Gaussian,
    /// this still transports the correct mass when sigma is below one pixel.
    /// The bounded tail is normalised; Double computes coefficients only, while
    /// the concentration transport itself runs in FP32 on the GPU.
    private static func diffusionWeights(variance: Double, radius: Int) -> [CIVector] {
        let half = variance / 2
        var leading = 1.0
        var values = [Double](repeating: 0, count: 28)
        for n in 0...radius {
            if n > 0 { leading *= half / Double(n) }
            var term = leading
            var sum = term
            for k in 1...160 {
                term *= half * half / (Double(k) * Double(k + n))
                sum += term
                if term <= sum * 1e-15 { break }
            }
            values[n] = exp(-variance) * sum
        }
        let total = values[0] + 2 * values.dropFirst().reduce(0, +)
        if total > 0 { values = values.map { $0 / total } }
        return stride(from: 0, to: 28, by: 4).map { i in
            CIVector(x: values[i], y: values[i + 1], z: values[i + 2], w: values[i + 3])
        }
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private struct Kernels: @unchecked Sendable {
        let activation: CIColorKernel?
        let saltStep: CIColorKernel?
        let developerStep: CIColorKernel?
        let replenish: CIColorKernel?
        let diffusion: CIKernel?
        let relativeGrowth: CIColorKernel?
        let composite: CIColorKernel?
    }

    private static let kernels: Kernels = {
        let useMetal = MTLCreateSystemDefaultDevice()?.supportsDynamicLibraries == true
        func make(_ name: String, parameters: String, body: String, helpers: String = "") -> CIColorKernel? {
            if useMetal {
                let metal = """
                #include <metal_stdlib>
                #include <CoreImage/CoreImage.h>
                using namespace metal;
                using namespace coreimage;
                \(helpers)
                [[ stitchable ]] float4 \(name)(\(parameters.replacingOccurrences(of: "__sample", with: "sample_t"))) { \(body) }
                """
                    .replacingOccurrences(of: "vec3", with: "float3")
                    .replacingOccurrences(of: "vec4", with: "float4")
                if let compiled = try? CIKernel.kernels(withMetalString: metal),
                   let kernel = compiled.first(where: { $0.name == name }) as? CIColorKernel {
                    return kernel
                }
            }
            return CIColorKernel(source: "\(helpers)\nkernel vec4 \(name)(\(parameters)) { \(body) }")
        }
        // Crystal volume growth for a frozen developer concentration. Limiting
        // uptake by the remaining shared pool keeps both reagents nonnegative,
        // even at the longest development time and the coarsest allowed step.
        let reactionHelpers = """
            vec3 growthDemand(vec3 active, vec3 salt, vec3 developer, float rate) {
                // Infer radius from conserved developed volume N*(r^3-r0^3).
                // Surface area now affects uptake; this is not first-order decay.
                vec3 radius = pow(vec3(0.125) + (vec3(1.0)-salt) / max(active, vec3(0.000001)), vec3(1.0/3.0));
                vec3 dr = 0.28 * rate * salt * developer;
                vec3 volume = active * dr * (3.0 * radius * radius + 3.0 * radius * dr + dr * dr);
                return min(salt, max(volume, vec3(0.0)));
            }
            vec3 developmentUptake(vec3 active, vec3 salt, float developer, float rate) {
                vec3 demand = growthDemand(active, salt, vec3(developer), rate);
                float consumption = 1.6 * dot(demand, vec3(1.0 / 3.0));
                return demand * min(1.0, developer / max(consumption, 0.0000001));
            }
            """
        let activation = make("filmDevelopmentActivation", parameters: "__sample image", body: """
            vec3 rgb = max(image.rgb / max(image.a, 0.00000001), vec3(0.0));
            // The bounded activation describes the fraction of latent centres;
            // HDR source values are retained separately in the final composite.
            vec3 active = vec3(1.0) - vec3(0.18) / (rgb + vec3(0.18));
            return vec4(clamp(active, 0.0, 1.0), 1.0);
            """)
        let saltStep = make("filmDevelopmentSalt", parameters: "__sample active, __sample salt, __sample developer, float rate", body: """
            vec3 uptake = developmentUptake(active.rgb, salt.rgb, developer.r, rate);
            return vec4(max(salt.rgb - uptake, vec3(0.0)), 1.0);
            """, helpers: reactionHelpers)
        let developerStep = make("filmDevelopmentPool", parameters: "__sample active, __sample salt, __sample developer, float rate", body: """
            vec3 uptake = developmentUptake(active.rgb, salt.rgb, developer.r, rate);
            float remaining = max(developer.r - 1.6 * dot(uptake, vec3(1.0 / 3.0)), 0.0);
            return vec4(vec3(remaining), 1.0);
            """, helpers: reactionHelpers)
        let replenish = make("filmDevelopmentSupply", parameters: "__sample developer, float supplied", body: """
            return vec4(vec3(mix(clamp(developer.r, 0.0, 1.0), 1.0, supplied)), 1.0);
            """)
        // Accumulate differences from the centre in FP32. A constant field is
        // then exactly fixed, rather than drifting through repeated approximate
        // filter normalisation. The bounded stencil convolves developer only.
        let diffusionBody = """
            vec2 p = destCoord();
            float centre = sample(source, samplerTransform(source, p)).r;
            float delta = 0.0;
            float weights = w0.x;
            for (int i = 1; i <= 24; ++i) {
                if (float(i) <= radius) {
                    float d = float(i);
                    vec4 group = i < 4 ? w0 : (i < 8 ? w1 : (i < 12 ? w2 : (i < 16 ? w3 : (i < 20 ? w4 : (i < 24 ? w5 : w6)))));
                    float weight = group[i % 4];
                    float left = sample(source, samplerTransform(source, p - axis * d)).r;
                    float right = sample(source, samplerTransform(source, p + axis * d)).r;
                    delta += weight * ((left - centre) + (right - centre));
                    weights += 2.0 * weight;
                }
            }
            return vec4(vec3(centre + delta / weights), 1.0);
            """
        let diffusion: CIKernel?
        if useMetal {
            let body = diffusionBody.replacingOccurrences(of: "destCoord()", with: "dest.coord()")
                .replacingOccurrences(of: "sample(source, samplerTransform(source, p))", with: "source.sample(source.transform(p))")
                .replacingOccurrences(of: "sample(source, samplerTransform(source, p - axis * d))", with: "source.sample(source.transform(p - axis * d))")
                .replacingOccurrences(of: "sample(source, samplerTransform(source, p + axis * d))", with: "source.sample(source.transform(p + axis * d))")
                .replacingOccurrences(of: "vec2", with: "float2")
                .replacingOccurrences(of: "vec3", with: "float3")
                .replacingOccurrences(of: "vec4", with: "float4")
            let code = """
                #include <metal_stdlib>
                #include <CoreImage/CoreImage.h>
                using namespace metal;
                using namespace coreimage;
                [[ stitchable ]] float4 filmDevelopmentDiffusion(coreimage::sampler source, float2 axis, float4 w0, float4 w1, float4 w2, float4 w3, float4 w4, float4 w5, float4 w6, float radius, destination dest) { \(body) }
                """
            do { diffusion = try CIKernel.kernels(withMetalString: code).first(where: { $0.name == "filmDevelopmentDiffusion" }) }
            catch { diffusion = nil }
        } else {
            diffusion = CIKernel(source: "kernel vec4 filmDevelopmentDiffusion(sampler source, vec2 axis, vec4 w0, vec4 w1, vec4 w2, vec4 w3, vec4 w4, vec4 w5, vec4 w6, float radius) { \(diffusionBody) }")
        }
        let relativeGrowth = make("filmDevelopmentRelativeGrowth", parameters: "__sample active, __sample salt, float rate, float supplied, float steps, float amount", body: """
            vec3 referenceSalt = vec3(1.0);
            vec3 referenceDeveloper = vec3(1.0);
            for (int i = 0; i < 48; ++i) {
                if (float(i) < steps) {
                    vec3 demand = growthDemand(active.rgb, referenceSalt, referenceDeveloper, rate);
                    vec3 uptake = demand * min(vec3(1.0), referenceDeveloper / max(1.6 * demand, vec3(0.0000001)));
                    referenceSalt = max(referenceSalt - uptake, vec3(0.0));
                    referenceDeveloper = mix(max(referenceDeveloper - 1.6 * uptake, vec3(0.0)), vec3(1.0), supplied);
                }
            }
            vec3 actual = max(vec3(1.0) - salt.rgb, vec3(0.0));
            vec3 reference = max(vec3(1.0) - referenceSalt, vec3(0.0));
            // A small latent-image floor avoids unstable ratios near pure black.
            vec3 relative = (actual + vec3(0.0001)) / (reference + vec3(0.0001));
            vec3 correction = exp(clamp(log(relative), -0.7, 0.7) * amount);
            return vec4(correction, 1.0);
            """, helpers: reactionHelpers)
        let composite = make("filmDevelopmentComposite", parameters: "__sample image, __sample correction", body: """
            // Multiplicative correction preserves premultiplication, signed RGB,
            // and HDR headroom. Alpha is copied without being developed.
            return vec4(image.rgb * correction.rgb, image.a);
            """)
        return Kernels(activation: activation, saltStep: saltStep, developerStep: developerStep,
                       replenish: replenish, diffusion: diffusion, relativeGrowth: relativeGrowth, composite: composite)
    }()
}
