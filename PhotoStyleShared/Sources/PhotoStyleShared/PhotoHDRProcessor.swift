import CoreImage

public enum PhotoHDRProcessor {
    private static let luminanceKernel = CIColorKernel(source: """
    kernel vec4 hdrLuminance(__sample source) {
        float luminance = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
        return vec4(luminance, luminance, luminance, source.a);
    }
    """)

    private static let logLuminanceKernel = CIColorKernel(source: """
    kernel vec4 hdrLogLuminance(__sample luminance) {
        float value = log2(max(luminance.r, 0.00001));
        return vec4(value, value, value, luminance.a);
    }
    """)

    private static let squaredLuminanceKernel = CIColorKernel(source: """
    kernel vec4 hdrSquaredLuminance(__sample source) {
        float value = source.r * source.r;
        return vec4(value, value, value, source.a);
    }
    """)

    private static let guidedCoefficientsKernel = CIColorKernel(source: """
    kernel vec4 hdrGuidedCoefficients(
        __sample mean,
        __sample correlation,
        float epsilon
    ) {
        float variance = max(correlation.r - mean.r * mean.r, 0.0);
        float slope = variance / (variance + epsilon);
        float intercept = mean.r * (1.0 - slope);
        return vec4(slope, intercept, 0.0, 1.0);
    }
    """)

    private static let guidedBaseKernel = CIColorKernel(source: """
    kernel vec4 hdrGuidedBase(__sample guide, __sample coefficients) {
        float value = coefficients.r * guide.r + coefficients.g;
        return vec4(value, value, value, guide.a);
    }
    """)

    private static let reconstructionKernel = CIColorKernel(source: """
    float mapLocalHDRTone(
        float value,
        float black,
        float shadows,
        float midtones,
        float highlights,
        float white
    ) {
        float mappedValue;
        if (value <= 0.25) {
            float t = clamp(value / 0.25, 0.0, 1.0);
            t = t * t * (3.0 - 2.0 * t);
            mappedValue = value + mix(black, shadows - 0.25, t);
        } else if (value <= 0.50) {
            float t = clamp((value - 0.25) / 0.25, 0.0, 1.0);
            t = t * t * (3.0 - 2.0 * t);
            mappedValue = value + mix(shadows - 0.25, midtones - 0.50, t);
        } else if (value <= 0.75) {
            float t = clamp((value - 0.50) / 0.25, 0.0, 1.0);
            t = t * t * (3.0 - 2.0 * t);
            mappedValue = value + mix(midtones - 0.50, highlights - 0.75, t);
        } else {
            float t = clamp((value - 0.75) / 0.25, 0.0, 1.0);
            t = t * t * (3.0 - 2.0 * t);
            mappedValue = value + mix(highlights - 0.75, white - 1.0, t);
        }
        return max(mappedValue, 0.0);
    }

    kernel vec4 reconstructLocalHDR(
        __sample source,
        __sample logLuminance,
        __sample baseLogLuminance,
        float black,
        float shadows,
        float midtones,
        float highlights,
        float white,
        float detailGain,
        float amount
    ) {
        float baseValue = max(exp2(baseLogLuminance.r), 0.0);
        float mappedBase = mapLocalHDRTone(
            baseValue,
            black,
            shadows,
            midtones,
            highlights,
            white
        );
        float detail = logLuminance.r - baseLogLuminance.r;
        float textureWeight = 1.0 - smoothstep(0.08, 0.35, abs(detail));
        float resolvedDetailGain = 1.0 + (detailGain - 1.0) * textureWeight;
        float localLogLuminance = log2(max(mappedBase, 0.00001))
            + detail * resolvedDetailGain;
        float directLuminance = mapLocalHDRTone(
            max(exp2(logLuminance.r), 0.0),
            black,
            shadows,
            midtones,
            highlights,
            white
        );
        float directLogLuminance = log2(max(directLuminance, 0.00001));
        float processedLogLuminance = mix(
            directLogLuminance,
            localLogLuminance,
            textureWeight
        );
        float outputLogLuminance = mix(logLuminance.r, processedLogLuminance, amount);
        float sourceLuminance = max(exp2(logLuminance.r), 0.0);
        float outputLuminance = max(exp2(outputLogLuminance), 0.0);
        vec3 chroma = source.rgb - vec3(sourceLuminance);
        float channelCeiling = max(max(max(source.r, source.g), source.b), 1.0);

        float gamutScale = 1.0;
        if (chroma.r > 0.000001) {
            gamutScale = min(gamutScale, (channelCeiling - outputLuminance) / chroma.r);
        } else if (chroma.r < -0.000001) {
            gamutScale = min(gamutScale, -outputLuminance / chroma.r);
        }
        if (chroma.g > 0.000001) {
            gamutScale = min(gamutScale, (channelCeiling - outputLuminance) / chroma.g);
        } else if (chroma.g < -0.000001) {
            gamutScale = min(gamutScale, -outputLuminance / chroma.g);
        }
        if (chroma.b > 0.000001) {
            gamutScale = min(gamutScale, (channelCeiling - outputLuminance) / chroma.b);
        } else if (chroma.b < -0.000001) {
            gamutScale = min(gamutScale, -outputLuminance / chroma.b);
        }

        vec3 outputColor = vec3(outputLuminance) + chroma * clamp(gamutScale, 0.0, 1.0);
        return vec4(max(outputColor, vec3(0.0)), source.a);
    }
    """)

    public static func curve(
        inferredFromAI toneZones: PhotoStylePlan.ToneZones
    ) -> PhotoStylePlan.HDRToneCurve {
        func toneValue(_ value: Int) -> Double { Double(clamped(value, to: -100...100)) }
        let shadows = toneZones.shadows
        let midtones = toneZones.midtones
        let highlights = toneZones.highlights
        let shadowLiftValue = max(0, toneValue(shadows.shadows)) * 0.28
            + max(0, toneValue(shadows.exposure)) * 0.12
            + max(0, toneValue(shadows.softness)) * 0.05
        let shadowLift = clamped(Int(shadowLiftValue.rounded()), to: 0...14)
        let highlightRecoveryValue = max(0, toneValue(highlights.highlights)) * 0.30
            + max(0, -toneValue(highlights.exposure)) * 0.10
            + max(0, toneValue(highlights.softness)) * 0.05
        let highlightRecovery = clamped(
            Int(highlightRecoveryValue.rounded()),
            to: 0...14
        )
        let midtoneShift = clamped(
            Int((toneValue(midtones.exposure) * 0.08).rounded()),
            to: -5...5
        )
        let detail = clamped(
            [shadows.contrast, midtones.contrast, highlights.contrast]
                .map { max(0, toneValue($0)) }
                .max()
                .map { Int(($0 * 0.25).rounded()) } ?? 0,
            to: 0...16
        )

        return .init(
            black: 0,
            shadows: 25 + shadowLift,
            midtones: 50 + midtoneShift,
            highlights: 75 - highlightRecovery,
            white: 100,
            detail: detail
        )
    }

    public static func apply(
        to image: CIImage,
        curve: PhotoStylePlan.HDRToneCurve?,
        amount: Double = 1
    ) -> CIImage {
        let resolvedAmount = min(max(amount, 0), 1)
        guard let curve,
              resolvedAmount > 0.0001,
              curve.hasVisibleEffect else {
            return image
        }

        let originalExtent = image.extent
        let normalizedImage = image.transformed(
            by: CGAffineTransform(
                translationX: -originalExtent.minX,
                y: -originalExtent.minY
            )
        )
        guard
              let luminanceKernel,
              let logLuminanceKernel,
              let reconstructionKernel,
              let luminance = luminanceKernel.apply(
                extent: normalizedImage.extent,
                arguments: [normalizedImage]
              ),
              let logLuminance = logLuminanceKernel.apply(
                extent: normalizedImage.extent,
                arguments: [luminance]
              ) else {
            return image
        }

        let baseLogLuminance = makeBaseLayer(
            logLuminance: logLuminance,
            extent: normalizedImage.extent
        )
        let points = resolvedControlPoints(curve)
        let detailGain = 1 + Double(clamped(curve.detail, to: 0...40)) / 40 * 0.10
        guard let output = reconstructionKernel.apply(
            extent: normalizedImage.extent,
            arguments: [
                normalizedImage,
                logLuminance,
                baseLogLuminance,
                points.black,
                points.shadows,
                points.midtones,
                points.highlights,
                points.white,
                Float(detailGain),
                Float(resolvedAmount)
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

    private static func makeBaseLayer(
        logLuminance: CIImage,
        extent: CGRect
    ) -> CIImage {
        let shortEdge = max(min(extent.width, extent.height), 1)
        let scale = min(256 / shortEdge, 0.5)
        let sampledLogLuminance = logLuminance.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let radius = min(max(shortEdge * scale / 32, 2), 8)

        if let guidedBase = makeGuidedBaseLayer(
            sampledLogLuminance: sampledLogLuminance,
            fullResolutionLogLuminance: logLuminance,
            radius: radius,
            scale: scale,
            extent: extent
        ) {
            return guidedBase
        }

        let fallbackRadius = min(max(shortEdge / 64, 2), 24)
        return logLuminance
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: fallbackRadius
            ])
            .cropped(to: extent)
    }

    private static func makeGuidedBaseLayer(
        sampledLogLuminance: CIImage,
        fullResolutionLogLuminance: CIImage,
        radius: CGFloat,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage? {
        guard let squaredLuminanceKernel,
              let guidedCoefficientsKernel,
              let guidedBaseKernel,
              let squaredLuminance = squaredLuminanceKernel.apply(
                extent: sampledLogLuminance.extent,
                arguments: [sampledLogLuminance]
              ) else {
            return nil
        }

        let mean = boxBlur(sampledLogLuminance, radius: radius)
        let correlation = boxBlur(squaredLuminance, radius: radius)
        guard let coefficients = guidedCoefficientsKernel.apply(
            extent: sampledLogLuminance.extent,
            arguments: [mean, correlation, Float(0.0015)]
        ) else {
            return nil
        }

        let averagedCoefficients = boxBlur(coefficients, radius: radius)
        let upsampledCoefficients = averagedCoefficients
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
        return guidedBaseKernel.apply(
            extent: extent,
            arguments: [fullResolutionLogLuminance, upsampledCoefficients]
        )?.cropped(to: extent)
    }

    private static func boxBlur(_ image: CIImage, radius: CGFloat) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [
                kCIInputRadiusKey: radius
            ])
            .cropped(to: image.extent)
    }

    private static func resolvedControlPoints(
        _ curve: PhotoStylePlan.HDRToneCurve
    ) -> (
        black: Float,
        shadows: Float,
        midtones: Float,
        highlights: Float,
        white: Float
    ) {
        // These are output luminances, not fixed aesthetic ranges. Keep valid
        // requested landmarks, including equal neighbors, and repair only bounds
        // and ordering for callers that construct curves directly.
        let black = clamped(curve.black, to: 0...100)
        let shadows = clamped(curve.shadows, to: black...100)
        let midtones = clamped(curve.midtones, to: shadows...100)
        let highlights = clamped(curve.highlights, to: midtones...100)
        let white = clamped(curve.white, to: highlights...100)

        return (
            Float(black) / 100,
            Float(shadows) / 100,
            Float(midtones) / 100,
            Float(highlights) / 100,
            Float(white) / 100
        )
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
