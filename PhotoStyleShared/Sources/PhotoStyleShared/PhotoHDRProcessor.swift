import CoreImage

public enum PhotoHDRProcessor {
    /// 手動 HDR 不依賴 AI 分析；保留黑白端點，抬升暗部並壓縮亮部。
    public static let manualCurve = PhotoStylePlan.HDRToneCurve(
        black: 0, shadows: 38, midtones: 50, highlights: 64, white: 100, detail: 12
    )

    // Fuse scalar luminance extraction and log encoding. Preserve the original
    // working-space convention and HDR curve; no conversion to Lab is involved.
    private static let logLuminanceKernel = PhotoGPUColorKernel.make("hdrLogLuminance", parameters: "__sample source", body: """
        vec3 color = source.rgb / max(source.a, 0.00001);
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float value = log2(max(luminance, 0.00001));
        return vec4(value, value, value, 1.0);
        """)

    private static let reconstructionKernel = CIColorKernel(source: """
    float hdrSlope(float left, float right) {
        return left > 0.0 && right > 0.0 ? 2.0 * left * right / (left + right) : 0.0;
    }

    float hdrSegment(float x, float y0, float y1, float m0, float m1) {
        float t = clamp(x, 0.0, 1.0);
        float t2 = t * t;
        float t3 = t2 * t;
        return (2.0*t3 - 3.0*t2 + 1.0)*y0 + (t3 - 2.0*t2 + t)*m0
             + (-2.0*t3 + 3.0*t2)*y1 + (t3 - t2)*m1;
    }

    float mapLocalHDRTone(
        float value, float black, float shadows, float midtones, float highlights, float white
    ) {
        // 單調 Hermite 插值；相鄰控制點相等時不會反轉亮度。
        float d0 = shadows - black;
        float d1 = midtones - shadows;
        float d2 = highlights - midtones;
        float d3 = white - highlights;
        float m1 = hdrSlope(d0, d1);
        float m2 = hdrSlope(d1, d2);
        float m3 = hdrSlope(d2, d3);
        if (value <= 0.25) return hdrSegment(value * 4.0, black, shadows, d0, m1);
        if (value <= 0.50) return hdrSegment((value-0.25)*4.0, shadows, midtones, m1, m2);
        if (value <= 0.75) return hdrSegment((value-0.50)*4.0, midtones, highlights, m2, m3);
        if (value <= 1.0) return hdrSegment((value-0.75)*4.0, highlights, white, m3, d3);
        return white + value - 1.0;
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
        vec3 sourceColor = source.rgb / max(source.a, 0.00001);
        vec3 chroma = sourceColor - vec3(sourceLuminance);
        float channelCeiling = max(max(max(sourceColor.r, sourceColor.g), sourceColor.b), 1.0);

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
        return vec4(max(outputColor, vec3(0.0)) * source.a, source.a);
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
        amount: Double = 1,
        renderContext: CIContext? = nil
    ) -> CIImage {
        guard amount.isFinite, !image.extent.isEmpty, !image.extent.isInfinite else { return image }
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
              let logLuminanceKernel,
              let reconstructionKernel,
              let logLuminance = logLuminanceKernel.apply(
                extent: normalizedImage.extent,
                arguments: [normalizedImage]
              ) else {
            return image
        }

        let baseLogLuminance = PhotoFastGuidedFilter.smooth(
            logLuminance, maximumSampleShortEdge: 256, epsilon: 0.0015, renderContext: renderContext
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
