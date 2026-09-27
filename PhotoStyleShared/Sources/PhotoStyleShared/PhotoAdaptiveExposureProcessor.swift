import CoreImage

public enum PhotoAdaptiveExposureProcessor {
    private static let illuminationKernel = CIColorKernel(source: """
    kernel vec4 exposureIllumination(__sample source) {
        vec3 rgb = source.rgb / max(source.a, 0.000001);
        float value = max(rgb.r, max(rgb.g, rgb.b));
        return vec4(value, value, value, 1.0);
    }
    """)

    private static let responseKernel = """
    float bimefResponse(float value, float exposureRatio) {
        float gamma = pow(exposureRatio, -0.3293);
        float beta = exp((1.0 - gamma) * 1.1258);
        return beta * pow(max(value, 0.0), gamma);
    }
    """

    private static let exposureKernel = CIColorKernel(source: """
    \(PhotoExposureProtection.kernel)
    \(responseKernel)

    kernel vec4 adaptiveExposure(
        __sample source,
        __sample illumination,
        float exposureValue
    ) {
        if (source.a <= 0.0) { return vec4(0.0); }
        vec3 straight = source.rgb / source.a;
        float sourcePeak = max(straight.r, max(straight.g, straight.b));
        if (sourcePeak <= 0.00001) {
            return source;
        }

        float localIllumination = max(illumination.r, 0.0);
        float outputPeak = sourcePeak;
        if (exposureValue > 0.0) {
            float exposureRatio = exp2(exposureValue);
            float candidatePeak = bimefResponse(sourcePeak, exposureRatio);
            float originalWeight = pow(clamp(localIllumination, 0.0, 1.0), 0.5);
            outputPeak = min(mix(candidatePeak, sourcePeak, originalWeight),
                             protectedExposurePeak(sourcePeak, exposureRatio));
        } else {
            float physicalTarget = sourcePeak * exp2(exposureValue);
            float participation = pow(
                smoothstep(0.015, 0.85, localIllumination),
                0.65
            );
            outputPeak = max(mix(sourcePeak, physicalTarget, participation),
                             protectedExposurePeak(sourcePeak, exp2(exposureValue)));
        }

        float scale = max(outputPeak, 0.0) / sourcePeak;
        return vec4(max(source.rgb * scale, vec3(0.0)), source.a);
    }
    """)

    // Reuse the digital exposure response and local illumination, but retain
    // film EV zoning and exact negative EV. This is a separate optional path.
    private static let filmExposureKernel = PhotoGPUColorKernel.make("adaptiveFilmExposure",
        parameters: "__sample source, __sample illumination, vec3 zones, float protection, float amount",
        body: """
        if (source.a <= 0.0) return vec4(0.0);
        vec3 rgb = source.rgb / source.a;
        float y = dot(rgb, vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        float ev = zoneExposureEV(y, zones);
        float gain = exp2(ev);
        float peak = max(rgb.r,max(rgb.g,rgb.b));
        float scale = gain;
        if (protection > 0.5 && ev > 0.0 && peak > 0.00001) {
            float candidate = bimefResponse(peak,gain);
            float originalWeight = sqrt(clamp(illumination.r,0.0,1.0));
            float target = min(mix(candidate,peak,originalWeight),protectedExposurePeak(peak,gain));
            scale = max(peak,target)/peak;
        }
        return vec4(rgb * mix(1.0,scale,amount) * source.a,source.a);
        """, helpers: PhotoExposureProtection.kernel + PhotoExposureProtection.zoneKernel + responseKernel)

    static func applyFilmExposure(to image: CIImage, effects: PhotoFilmEffects,
                                  strength: Double, renderContext: CIContext?) -> CIImage {
        let zones = effects.resolvedPrintExposure
        let amount = strength.isFinite ? min(1,max(0,strength)) : 0
        guard zones != .zero, amount > 0, !image.extent.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let linear = image.matchedFromWorkingSpace(to: space),
              let filmExposureKernel else { return image }
        let illumination: CIImage
        if effects.highlightProtectionEnabled && max(zones.x,max(zones.y,zones.z)) > 0 {
            guard let initial = illuminationKernel?.apply(extent: linear.extent, arguments: [linear]) else { return image }
            illumination = PhotoFastGuidedFilter.smooth(initial, renderContext: renderContext)
        } else {
            // No local statistics are needed for negative EV or protection off.
            illumination = linear
        }
        guard let output = filmExposureKernel.apply(extent: linear.extent, arguments: [linear,illumination,
            CIVector(x: zones.x,y: zones.y,z: zones.z),effects.highlightProtectionEnabled ? 1.0 : 0.0,amount]),
              let adjusted = output.matchedToWorkingSpace(from: space) else { return image }
        return PhotoLabAdjustmentProcessor.replacingLightness(of: image, with: adjusted).cropped(to: image.extent)
    }

    public static func apply(to image: CIImage, ev: Double, renderContext: CIContext? = nil) -> CIImage {
        let exposureValue = ev.isFinite ? min(max(ev, -4), PhotoExposureScale.maximumEV) : 0
        guard abs(exposureValue) > 0.001,
              !image.extent.isEmpty,
              let illuminationKernel,
              let exposureKernel else {
            return image
        }

        let originalExtent = image.extent
        let normalizedImage = image.transformed(
            by: CGAffineTransform(
                translationX: -originalExtent.minX,
                y: -originalExtent.minY
            )
        )
        guard let initialIllumination = illuminationKernel.apply(
            extent: normalizedImage.extent,
            arguments: [normalizedImage]
        ) else {
            return image
        }
        let illumination = PhotoFastGuidedFilter.smooth(initialIllumination, renderContext: renderContext)
        guard let output = exposureKernel.apply(
            extent: normalizedImage.extent,
            arguments: [normalizedImage, illumination, Float(exposureValue)]
        ) else {
            return image
        }

        return output
            .transformed(
                by: CGAffineTransform(
                    translationX: originalExtent.minX,
                    y: originalExtent.minY
                )
            )
            .cropped(to: originalExtent)
    }
}
