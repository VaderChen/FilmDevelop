import CoreImage

public enum PhotoLocalToneProcessor {
    private static let logLuminanceKernel = CIColorKernel(source: """
    kernel vec4 localToneLogLuminance(__sample source) {
        vec3 color = source.rgb / max(source.a, 1.0e-20);
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float value = log2(max(luminance, 0.000001));
        return vec4(value, value, value, 1.0);
    }
    """)

    private static let reconstructionKernel = CIColorKernel(source: """
    float localToneSmoothSlope(float low, float high, float value) {
        float t = clamp((value - low) / (high - low), 0.0, 1.0);
        return 6.0 * t * (1.0 - t) / (high - low);
    }

    vec2 mapLocalToneStops(
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
        float protectionSlope = shadows < 0.0 ? localToneSmoothSlope(-5.5, -2.8, stops) : 0.0;
        float slope = contrastGain + shadows * 0.75 * (
            shadowWeight * protectionSlope - shadowProtection * localToneSmoothSlope(-2.3, 0.9, stops))
            - highlights * 0.55 * localToneSmoothSlope(0.4, 2.5, stops);
        return vec2(mappedStops, max(slope, 0.0));
    }

    // Monotone rational quadratic Hermite: keeps the weak-texture derivative
    // and joins the direct tone curve at strong edges without blend reversal.
    float localToneDetailSegment(float t, float y0, float y1, float m0, float m1, float width) {
        float delta = max(y1 - y0, 0.0);
        float secant = delta / width;
        if (secant < 0.000001) return mix(y0, y1, t);
        // Nonnegative endpoint slopes bound the denominator below by secant / 2.
        float cross = t * (1.0 - t);
        return y0 + delta * (secant * t * t + m0 * cross)
            / (secant + (m0 + m1 - 2.0 * secant) * cross);
    }

    kernel vec4 reconstructLocalTone(
        __sample source,
        __sample logLuminance,
        __sample baseLogLuminance,
        float contrast,
        float highlights,
        float shadows
    ) {
        if (source.a <= 0.0) return source;
        vec3 color = source.rgb / source.a;
        float signedLuminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        // No useful log tone exists at nonpositive Y. Retain signed source
        // components rather than clipping them into a different color/energy.
        if (signedLuminance <= 0.0) return source;
        float pivotLogLuminance = log2(0.18);
        float sourceLogLuminance = logLuminance.r;
        float baseLog = baseLogLuminance.r;
        float baseStops = baseLog - pivotLogLuminance;
        float detail = sourceLogLuminance - baseLog;
        float detailGain = 1.0
            + max(contrast, 0.0) * 0.12
            + min(contrast, 0.0) * 0.08;
        float directStops = sourceLogLuminance - pivotLogLuminance;
        float radius = 0.45;
        float outputStops = mapLocalToneStops(directStops, contrast, highlights, shadows).x;
        if (abs(detail) < radius) {
            vec2 middle = mapLocalToneStops(baseStops, contrast, highlights, shadows);
            if (detail < 0.0) {
                vec2 left = mapLocalToneStops(baseStops - radius, contrast, highlights, shadows);
                outputStops = localToneDetailSegment((detail + radius) / radius,
                    left.x, middle.x, left.y, detailGain, radius);
            } else {
                vec2 right = mapLocalToneStops(baseStops + radius, contrast, highlights, shadows);
                outputStops = localToneDetailSegment(detail / radius,
                    middle.x, right.x, detailGain, right.y, radius);
            }
        }
        float outputLogLuminance = pivotLogLuminance + outputStops;
        float sourceLuminance = max(exp2(sourceLogLuminance), 0.000001);
        float outputLuminance = max(exp2(outputLogLuminance), 0.0);
        float scale = outputLuminance / sourceLuminance;
        // A rational toe joins identity at Y=0 to the floor's positive gain.
        // Unlike smoothstep blending of gains, it stays monotone even when
        // positive contrast makes the floor gain much smaller than one.
        if (signedLuminance < 0.000001) {
            float t = signedLuminance / 0.000001;
            scale = scale * (scale * t + 1.0 - t)
                / (scale + (1.0 - scale) * t * (1.0 - t));
        }
        return vec4(source.rgb * scale, source.a);
    }
    """)

    public static func apply(
        to image: CIImage,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        renderContext: CIContext? = nil
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
            epsilon: 0.01,
            renderContext: renderContext
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
