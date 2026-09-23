import CoreImage

public enum PhotoRAWDynamicRangeProcessor {
    private static let highlightCompandingKernel = CIColorKernel(source: """
    kernel vec4 compactRAWHighlightHeadroom(__sample source) {
        float peak = max(max(source.r, source.g), source.b);
        if (peak <= 0.78) {
            return source;
        }
        float mappedPeak = 0.78 + 0.22 * (1.0 - exp(-(peak - 0.78) / 0.22));
        float scale = mappedPeak / max(peak, 0.00001);
        return vec4(max(source.rgb * scale, vec3(0.0)), source.a);
    }
    """)

    public static func prepareForDisplayAdjustments(_ image: CIImage) -> CIImage {
        guard let highlightCompandingKernel,
              let output = highlightCompandingKernel.apply(
                extent: image.extent,
                arguments: [image]
              ) else {
            return image
        }
        return output.cropped(to: image.extent)
    }
}
