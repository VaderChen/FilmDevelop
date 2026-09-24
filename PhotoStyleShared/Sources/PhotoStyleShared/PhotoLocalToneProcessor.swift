import CoreImage

public enum PhotoLocalToneProcessor {
    private static let logLuminanceKernel = CIColorKernel(source: """
    kernel vec4 localToneLogLuminance(__sample source) {
        vec3 color = max(source.rgb / max(source.a, 0.00001), vec3(0.0));
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float value = log2(max(luminance, 0.000001));
        return vec4(value, value, value, 1.0);
    }
    """)

    private static let reconstructionKernel = CIColorKernel(source: """
    float mapLocalToneStops(
        float stops,
        float contrast,
        float highlights,
        float shadows
    ) {
        float contrastGain = 1.0 + contrast * 0.45;
        float mappedStops = stops * contrastGain;
        float shadowWeight = 1.0 - smoothstep(-2.3, 0.9, stops);
        float shadowProtection = shadows < 0.0
            ? smoothstep(-5.5, -2.8, stops)
            : 1.0;
        float highlightWeight = smoothstep(0.4, 2.5, stops);
        mappedStops += shadows * 0.75 * shadowWeight * shadowProtection;
        mappedStops -= highlights * 0.55 * highlightWeight;
        return mappedStops;
    }

    kernel vec4 reconstructLocalTone(
        __sample source,
        __sample logLuminance,
        __sample baseLogLuminance,
        float contrast,
        float highlights,
        float shadows
    ) {
        float pivotLogLuminance = log2(0.18);
        float sourceLogLuminance = logLuminance.r;
        float baseLog = baseLogLuminance.r;
        float baseStops = baseLog - pivotLogLuminance;
        float detail = sourceLogLuminance - baseLog;
        float detailGain = 1.0
            + max(contrast, 0.0) * 0.12
            + min(contrast, 0.0) * 0.08;
        float localMappedLog = pivotLogLuminance
            + mapLocalToneStops(baseStops, contrast, highlights, shadows)
            + detail * detailGain;
        float directStops = sourceLogLuminance - pivotLogLuminance;
        float directMappedLog = pivotLogLuminance
            + mapLocalToneStops(directStops, contrast, highlights, shadows);
        float strongEdgeWeight = smoothstep(0.10, 0.45, abs(detail));
        float outputLogLuminance = mix(
            localMappedLog,
            directMappedLog,
            strongEdgeWeight
        );
        float sourceLuminance = max(exp2(sourceLogLuminance), 0.000001);
        float outputLuminance = max(exp2(outputLogLuminance), 0.0);
        float scale = outputLuminance / sourceLuminance;
        return vec4(max(source.rgb * scale, vec3(0.0)), source.a);
    }
    """)

    public static func apply(
        to image: CIImage,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0
    ) -> CIImage {
        guard [contrast, highlights, shadows].allSatisfy(\.isFinite),
              !image.extent.isInfinite else { return image }
        let contrast = min(max(contrast, -1), 1)
        let highlights = min(max(highlights, -1), 1)
        let shadows = min(max(shadows, -1), 1)
        guard abs(contrast) > 0.001
                || abs(highlights) > 0.001
                || abs(shadows) > 0.001,
              !image.extent.isEmpty,
              let logLuminanceKernel,
              let reconstructionKernel else {
            return image
        }

        let originalExtent = image.extent
        let normalizedImage = image.transformed(
            by: CGAffineTransform(
                translationX: -originalExtent.minX,
                y: -originalExtent.minY
            )
        )
        guard let logLuminance = logLuminanceKernel.apply(
            extent: normalizedImage.extent,
            arguments: [normalizedImage]
        ) else {
            return image
        }
        let baseLogLuminance = PhotoFastGuidedFilter.smooth(
            logLuminance,
            maximumSampleShortEdge: 256,
            epsilon: 0.01
        )
        guard let output = reconstructionKernel.apply(
            extent: normalizedImage.extent,
            arguments: [
                normalizedImage,
                logLuminance,
                baseLogLuminance,
                Float(contrast),
                Float(highlights),
                Float(shadows)
            ]
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
