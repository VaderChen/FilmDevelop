import CoreImage
import Foundation

/// A bounded local exposure lift in scene-linear RGB. A guided log-luminance
/// base determines the gain; the same gain is applied to all three channels.
/// This is a shadow control (0...100 percent), not a replacement for global EV.
public enum PhotoDeepShadowExposureProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let logKernel = PhotoGPUColorKernel.make("deepShadowLogLuminance",
        parameters: "__sample source", body: """
        vec3 rgb = source.rgb / max(source.a, 1.0e-20);
        float y = dot(rgb, vec3(0.2126390059, 0.7151686788, 0.0721923154));
        float guide = log2(max(y, 1.0e-8));
        return vec4(guide, guide, guide, 1.0);
        """)

    /// A small bilateral neighborhood limits amplified high-frequency
    /// color/luminance fluctuations. Its variance is only a local uncertainty
    /// heuristic: it is not a measured sensor noise model or a RAW denoiser.
    private static let neighborhoodKernel: CIKernel? = {
        let body = """
        vec2 p = destCoord();
        vec4 center = sample(source, samplerTransform(source, p));
        vec3 weights = vec3(0.2126390059, 0.7151686788, 0.0721923154);
        vec3 rgb = center.rgb / max(center.a, 1.0e-20);
        float y = dot(rgb, weights);
        float logY = log2(max(y, 1.0e-8));
        vec3 sum = vec3(0.0), squared = vec3(0.0);
        float total = 0.0;
        for (int row = -1; row <= 1; ++row) {
            for (int col = -1; col <= 1; ++col) {
                vec2 d = vec2(float(col), float(row));
                vec2 q = p + d * radius;
                vec4 neighbor = sample(source, samplerTransform(source, q));
                vec3 color = neighbor.rgb / max(neighbor.a, 1.0e-20);
                float ny = dot(color, weights);
                float logDelta = log2(max(ny, 1.0e-8)) - logY;
                vec3 chromaDelta = color / max(ny, 1.0e-6) - rgb / max(y, 1.0e-6);
                // Do not average across either luminance or equal-Y color edges.
                float w = exp(-0.5 * dot(d, d) - 8.0 * logDelta * logDelta
                              - 2.0 * dot(chromaDelta, chromaDelta));
                w *= clamp(neighbor.a, 0.0, 1.0);
                sum += color * w;
                squared += color * color * w;
                total += w;
            }
        }
        vec3 mean = total > 1.0e-8 ? sum / total : rgb;
        vec3 variance = max(squared / max(total, 1.0e-8) - mean * mean, vec3(0.0));
        float signal = max(dot(mean, weights), 0.0);
        float variation = dot(variance, weights);
        float uncertainty = variation / max(variation + 0.01 * signal * signal, 1.0e-20);
        // RGB and alpha carry DATA here: mean unassociated RGB / uncertainty.
        return vec4(mean, clamp(uncertainty, 0.0, 1.0));
        """
        if PhotoGPUColorKernel.supportsMetal {
            let metalBody = body.replacingOccurrences(of: "vec2", with: "float2")
                .replacingOccurrences(of: "vec3", with: "float3")
                .replacingOccurrences(of: "vec4", with: "float4")
                .replacingOccurrences(of: "destCoord()", with: "dest.coord()")
                .replacingOccurrences(of: "sample(source, samplerTransform(source, p))", with: "source.sample(source.transform(p))")
                .replacingOccurrences(of: "sample(source, samplerTransform(source, q))", with: "source.sample(source.transform(q))")
            let code = """
            #include <metal_stdlib>
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            using namespace coreimage;
            [[ stitchable ]] float4 deepShadowNeighborhood(coreimage::sampler source, float radius, destination dest) { \(metalBody) }
            """
            if let kernel = try? CIKernel.kernels(withMetalString: code).first { return kernel }
        }
        return CIKernel(source: "kernel vec4 deepShadowNeighborhood(sampler source, float radius) { \(body) }")
    }()

    private static let adjustmentKernel = PhotoGPUColorKernel.make("deepShadowLocalExposure",
        parameters: "__sample source, __sample logGuide, __sample base, __sample neighborhood, float amount", body: """
        if (source.a <= 0.0) return source;
        vec3 rgb = source.rgb / source.a;
        vec3 weights = vec3(0.2126390059, 0.7151686788, 0.0721923154);
        float y = dot(rgb, weights);
        if (y <= 1.0e-8 || y >= 0.8) return source;
        // Preserve scene headroom and negative wide-gamut components. No
        // per-channel clipping, Lab hue reconstruction, or output tone mapping.
        // Compress the base's stop distance to a bright pivot by only 55%.
        // A fixed target luminance would map an entire range to a flat plateau.
        // This retains 45% base contrast (and more at the six-stop limit).
        float pivotLog = log2(0.5);
        float localEV = clamp(0.55 * (pivotLog - base.r), 0.0, 6.0);
        float directEV = clamp(0.55 * (pivotLog - logGuide.r), 0.0, 6.0);
        // A large guide residual denotes an edge. Use the pointwise gain there
        // instead of bleeding a dark neighborhood's exposure into a bright edge.
        float edge = smoothstep(0.1, 0.4, abs(logGuide.r - base.r));
        float ev = mix(localEV, directEV, edge);
        ev *= 1.0 - smoothstep(0.12, 0.8, y);
        if (ev <= 0.0) return source;
        float gain = exp2(ev);
        float uncertainty = clamp(neighborhood.a, 0.0, 1.0);
        float cleanWeight = 0.6 * uncertainty * smoothstep(1.0, 4.0, ev)
                            * (1.0 - smoothstep(0.002, 0.02, y));
        vec3 clean = mix(rgb, neighborhood.rgb, cleanWeight);
        float cleanY = dot(clean, weights);
        if (cleanY <= 1.0e-8) { clean = rgb; cleanY = y; }
        // Local smoothing is bounded above; preserve at least 40% of the source
        // detail and never make a positive-luminance pixel darker in a lift tool.
        float outputY = max(y, cleanY * gain);
        vec3 lifted = clean * (outputY / cleanY);
        vec3 result = mix(rgb, lifted, amount);
        return vec4(result * source.a, source.a);
        """)

    public static func apply(to image: CIImage, amount: Double, strength: Double = 1,
                             renderContext: CIContext? = nil) -> CIImage {
        let value = (amount.isFinite ? min(100, max(0, amount)) / 100 : 0)
            * (strength.isFinite ? min(1, max(0, strength)) : 0)
        let extent = image.extent
        guard value > 0, !extent.isEmpty, !extent.isInfinite,
              [extent.minX, extent.minY, extent.maxX, extent.maxY].allSatisfy(\.isFinite),
              let logKernel, let neighborhoodKernel, let adjustmentKernel,
              let linear = image.matchedFromWorkingSpace(to: space),
              let guide = logKernel.apply(extent: extent, arguments: [linear]) else { return image }
        // The guided filter carries log-luminance data without a 0...1 clamp.
        // Only its small coefficient map is materialized when a context is given.
        let base = PhotoFastGuidedFilter.smooth(guide, maximumSampleShortEdge: 256,
                                              epsilon: 0.04, renderContext: renderContext)
        let radius = max(1, min(3, max(extent.width, extent.height) / 1440))
        guard let neighborhood = neighborhoodKernel.apply(extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -radius, dy: -radius) },
                arguments: [linear.clampedToExtent(), radius]),
              let result = adjustmentKernel.apply(extent: extent,
                arguments: [linear, guide, base, neighborhood, value]),
              let output = result.matchedToWorkingSpace(from: space) else { return image }
        return output.cropped(to: extent)
    }
}
