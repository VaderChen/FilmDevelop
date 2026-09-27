import CoreImage

public enum PhotoRAWDynamicRangeProcessor {
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let highlightCompandingKernel = CIColorKernel(source: """
    kernel vec4 compactRAWHighlightHeadroom(__sample source) {
        if (source.a <= 0.0) return source;
        vec3 rgb = source.rgb / source.a;
        float peak = max(max(rgb.r, rgb.g), rgb.b);
        if (peak <= 0.78) {
            return source;
        }
        float mappedPeak = 0.78 + 0.22 * (1.0 - exp(-(peak - 0.78) / 0.22));
        float scale = mappedPeak / max(peak, 0.00001);
        return vec4(source.rgb * scale, source.a);
    }
    """)

    public static func prepareForDisplayAdjustments(_ image: CIImage) -> CIImage {
        guard let highlightCompandingKernel,
              let linear = image.matchedFromWorkingSpace(to: linearSRGB),
              let output = highlightCompandingKernel.apply(
                extent: image.extent,
                arguments: [linear]
              ) else {
            return image
        }
        return (output.matchedToWorkingSpace(from: linearSRGB) ?? image).cropped(to: image.extent)
    }
}
