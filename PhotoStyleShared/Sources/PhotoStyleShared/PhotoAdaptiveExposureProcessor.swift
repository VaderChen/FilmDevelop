import CoreImage

public enum PhotoAdaptiveExposureProcessor {
    private static let illuminationKernel = CIColorKernel(source: """
    kernel vec4 exposureIllumination(__sample source) {
        vec3 rgb = source.rgb / max(source.a, 0.000001);
        float value = max(rgb.r, max(rgb.g, rgb.b));
        return vec4(value, value, value, 1.0);
    }
    """)

    private static let exposureKernel = CIColorKernel(source: """
    \(PhotoExposureProtection.kernel)
    float bimefResponse(float value, float exposureRatio) {
        float gamma = pow(exposureRatio, -0.3293);
        float beta = exp((1.0 - gamma) * 1.1258);
        return beta * pow(max(value, 0.0), gamma);
    }

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
