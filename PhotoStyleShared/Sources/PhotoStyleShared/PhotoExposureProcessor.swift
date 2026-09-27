import CoreImage

/// Scene-linear exposure. All channels receive the same gain; no Lab chroma
/// locking, display clipping or illumination estimate is part of an EV control.
public enum PhotoExposureProcessor {
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let kernel = PhotoGPUColorKernel.make("sceneLinearExposure",
        parameters: "__sample source, vec3 curve, float globalEV, float amount, float protection, float peakProtection", body: """
        if (source.a <= 0.0) return source;
        vec3 rgb = source.rgb / source.a;
        float y = dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        // Stored zones are absolute values. Their difference from the linked
        // control defines local corrections; global EV is a separate gain.
        // Adding one stop to the control and all stored zones therefore doubles
        // every pixel before the optional highlight shoulder.
        float gain = exp2(globalEV + zoneExposureEV(y,curve));
        float anchor = peakProtection > 0.5 ? max(rgb.r,max(rgb.g,rgb.b)) : y;
        if (protection > 0.5 && gain > 1.0 && anchor > 1.0e-20) {
            gain = protectedExposurePeak(anchor,gain)/anchor;
        }
        return vec4(source.rgb * mix(1.0,gain,amount), source.a);
        """, helpers: PhotoExposureProtection.kernel + PhotoExposureProtection.zoneKernel)

    public static func apply(to image: CIImage, ev: Double) -> CIImage {
        apply(to: image, zones: SIMD3(repeating: finiteEV(ev)))
    }

    public static func apply(to image: CIImage, highlightsEV: Double, midtonesEV: Double, shadowsEV: Double) -> CIImage {
        apply(to: image, zones: SIMD3(highlightsEV,midtonesEV,shadowsEV))
    }

    /// Zones are absolute highlights/midtones/shadows EV values. Local residuals
    /// are evaluated against globalEV, preserving linked global shifts as gains.
    /// Equal zones remain literal global EV, independent of the stored anchor.
    /// Highlight protection is intentionally separate from the exposure value.
    static func apply(to image: CIImage, zones: SIMD3<Double>, globalEV: Double = 0, strength: Double = 1,
                      protectsHighlights: Bool = false, protectsPeak: Bool = false) -> CIImage {
        let ev = SIMD3(finiteEV(zones.x),finiteEV(zones.y),finiteEV(zones.z))
        let globalEV = finiteEV(globalEV)
        let curve = PhotoExposureProtection.curveParameters(zones: ev - SIMD3(repeating: globalEV))
        let amount = strength.isFinite ? min(1,max(0,strength)) : 0
        guard ev != .zero, amount > 0, !image.extent.isEmpty, !image.extent.isInfinite,
              let kernel, let linear = image.matchedFromWorkingSpace(to: linearSRGB),
              let result = kernel.apply(extent: image.extent, arguments: [linear,
                CIVector(x:curve.x,y:curve.y,z:curve.z),globalEV,amount,protectsHighlights ? 1.0 : 0.0,protectsPeak ? 1.0 : 0.0]),
              let output = result.matchedToWorkingSpace(from: linearSRGB) else { return image }
        return output.cropped(to: image.extent)
    }

    private static func finiteEV(_ value: Double) -> Double {
        value.isFinite ? min(16,max(-16,value)) : 0
    }
}
