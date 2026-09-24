import CoreImage

/// RGB 聯合導向濾波：以照片的色彩邊界細化單通道遮罩。
/// He、Sun、Tang，Guided Image Filtering（TPAMI 2013），式 14–16；
/// He、Sun，Fast Guided Filter（2015）：低解析度估計係數、原解析度重建。
/// https://people.csail.mit.edu/kaiming/eccv10/index.html
/// https://arxiv.org/abs/1505.00996
public enum PhotoGuidedMaskRefiner {
    private static let guideKernel = CIColorKernel(source: """
    kernel vec4 maskGuide(__sample s) {
        vec3 rgb = max(s.rgb / max(s.a, 0.00001), vec3(0.0));
        // 僅壓縮引導訊號，保留 HDR 亮部邊界；不改動成品色彩。
        return vec4(rgb / (vec3(1.0) + rgb), 1.0);
    }
    """)

    private static let maskKernel = CIColorKernel(source: """
    kernel vec4 maskInput(__sample mask) {
        float p = clamp(mask.r, 0.0, 1.0);
        return vec4(p, p, p, 1.0);
    }
    """)

    private static let diagonalKernel = CIColorKernel(source: """
    kernel vec4 maskDiagonal(__sample guide) {
        return vec4(guide.rgb * guide.rgb, 1.0);
    }
    """)

    private static let crossKernel = CIColorKernel(source: """
    kernel vec4 maskCross(__sample g) {
        return vec4(g.r * g.g, g.r * g.b, g.g * g.b, 1.0);
    }
    """)

    private static let correlationKernel = CIColorKernel(source: """
    kernel vec4 maskCorrelation(__sample guide, __sample mask) {
        return vec4(guide.rgb * mask.r, 1.0);
    }
    """)

    private static let slopeKernel = CIColorKernel(source: """
    kernel vec4 maskSlope(__sample mean, __sample meanP, __sample diagonal,
                          __sample cross, __sample correlation, float epsilon) {
        vec3 d = max(diagonal.rgb - mean.rgb * mean.rgb, vec3(0.0)) + vec3(epsilon);
        vec3 c = cross.rgb - vec3(mean.r * mean.g, mean.r * mean.b, mean.g * mean.b);
        vec3 v = correlation.rgb - mean.rgb * meanP.r;
        // 解完整 3×3 RGB 共變異矩陣，不能省略跨色頻相關項。
        // LDLᵀ 分解避免行列式相減在接近單色時失去精度。
        float l10 = c.r / d.r;
        float l20 = c.g / d.r;
        float d1 = max(d.g - l10 * c.r, epsilon * 0.01);
        float l21 = (c.b - l20 * c.r) / d1;
        float d2 = max(d.b - l20 * c.g - l21 * l21 * d1, epsilon * 0.01);
        float y1 = v.g - l10 * v.r;
        float y2 = v.b - l20 * v.r - l21 * y1;
        float a2 = y2 / d2;
        float a1 = y1 / d1 - l21 * a2;
        float a0 = v.r / d.r - l10 * a1 - l20 * a2;
        return vec4(a0, a1, a2, 1.0);
    }
    """)

    private static let interceptKernel = CIColorKernel(source: """
    kernel vec4 maskIntercept(__sample mean, __sample meanP, __sample slope) {
        float b = meanP.r - dot(slope.rgb, mean.rgb);
        return vec4(b, b, b, 1.0);
    }
    """)

    private static let reconstructKernel = CIColorKernel(source: """
    kernel vec4 maskReconstruct(__sample guide, __sample meanA, __sample meanB, __sample source) {
        float q = clamp(dot(meanA.rgb, guide.rgb) + meanB.r, 0.0, 1.0);
        if (source.a <= 0.00001) { q = 0.0; }
        return vec4(q, q, q, 1.0);
    }
    """)

    /// 遮罩須與照片使用相同座標。超出照片的部分會裁掉；不推測或拉伸座標。
    /// radius 為原解析度的視窗半徑；epsilon 為壓縮後 RGB 引導空間的正則化量。
    public static func refine(
        _ mask: CIImage,
        guidedBy image: CIImage,
        radius: Double,
        epsilon: Double = 0.0004,
        maximumSampleLongEdge: CGFloat = 1024
    ) -> CIImage {
        let extent = image.extent
        guard isUsable(extent) else { return CIImage.empty() }
        let fallback = mask.cropped(to: extent)
        guard radius.isFinite, radius > 0,
              epsilon.isFinite, epsilon > 0,
              maximumSampleLongEdge.isFinite, maximumSampleLongEdge >= 1,
              let guideKernel, let maskKernel, let diagonalKernel, let crossKernel,
              let correlationKernel, let slopeKernel, let interceptKernel, let reconstructKernel
        else { return fallback }

        // 先平移到原點再縮放，避免裁切／旋轉後的 extent 導致取樣錯位。
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let source = image.transformed(by: origin)
        let fullExtent = source.extent
        guard let guide = guideKernel.apply(extent: fullExtent, arguments: [source]),
              let input = maskKernel.apply(extent: fullExtent, arguments: [fallback.transformed(by: origin)])
        else { return fallback }

        let scale = min(1, maximumSampleLongEdge / max(extent.width, extent.height))
        guard let sampling = PhotoFilterSampling(extent: fullExtent, scale: scale) else { return fallback }
        let sampledGuide = sampling.sample(guide)
        let sampledMask = sampling.sample(input)
        let bounds = sampling.sampledExtent
        let sampleRadius = min(64, max(1, (radius * scale).rounded()))
        guard let diagonal = diagonalKernel.apply(extent: bounds, arguments: [sampledGuide]),
              let cross = crossKernel.apply(extent: bounds, arguments: [sampledGuide]),
              let correlation = correlationKernel.apply(extent: bounds, arguments: [sampledGuide, sampledMask])
        else { return fallback }

        let mean = boxMean(sampledGuide, radius: sampleRadius).insertingIntermediate(cache: true)
        let meanP = boxMean(sampledMask, radius: sampleRadius).insertingIntermediate(cache: true)
        guard let slope = slopeKernel.apply(extent: bounds, arguments: [
            mean, meanP, boxMean(diagonal, radius: sampleRadius),
            boxMean(cross, radius: sampleRadius), boxMean(correlation, radius: sampleRadius),
            max(epsilon, 0.00001)
        ])?.insertingIntermediate(cache: true),
              let intercept = interceptKernel.apply(extent: bounds, arguments: [mean, meanP, slope])
        else { return fallback }

        func upsample(_ coefficients: CIImage) -> CIImage {
            sampling.reconstruct(boxMean(coefficients, radius: sampleRadius))
        }
        // 係數分開儲存且 alpha 固定為 1，避免負係數被當作預乘 alpha。
        return reconstructKernel.apply(extent: fullExtent, arguments: [
            guide, upsample(slope), upsample(intercept), source
        ])?.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent) ?? fallback
    }

    private static func boxMean(_ image: CIImage, radius: Double) -> CIImage {
        PhotoBoxMeanFilter.apply(image, radius: radius)
    }

    private static func isUsable(_ extent: CGRect) -> Bool {
        !extent.isInfinite && !extent.isEmpty
            && extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
    }
}
