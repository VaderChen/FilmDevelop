import CoreImage

/// 降噪使用的逐通道保邊濾波；與 C++／Vulkan 使用相同公式。柔膚另採多尺度亮度處理。
enum PhotoGuidedChannelFilter {
    // 以 alpha 作為樣本權重計算非預乘 RGB 的均值與變異數；透明像素沒有色彩證據。
    // a=var/(var+ε)、b=mean*(1-a)，再以視窗覆蓋率加權平均係數並重建。
    // 不透明影像退化為原自引導公式；輸出沿用來源 alpha，保留浮點高光。
    static func apply(_ image: CIImage, radius: Double, epsilon: Double) -> CIImage {
        let extent = image.extent
        guard let prepared = weightedInput?.apply(extent: extent, arguments: [image]),
              let squared = square?.apply(extent: extent, arguments: [prepared]) else { return image }
        func mean(_ value: CIImage) -> CIImage {
            PhotoBoxMeanFilter.apply(value, radius: radius)
        }
        let average = mean(prepared)
        guard let slope = coefficientA?.apply(extent: extent, arguments: [average, mean(squared), epsilon]),
              let intercept = coefficientB?.apply(extent: extent, arguments: [average, slope]),
              let result = reconstruction?.apply(extent: extent, arguments: [image, mean(slope), mean(intercept)]) else { return image }
        return result
    }

    private static let weightedInput = CIColorKernel(source: """
    kernel vec4 skinGuideInput(__sample image) {
        return image.a > 0.0 ? image : vec4(0.0);
    }
    """)
    private static let square = CIColorKernel(source: """
    kernel vec4 skinGuideSquare(__sample image) {
        return image.a > 0.0 ? vec4(image.rgb * image.rgb / image.a, image.a) : vec4(0.0);
    }
    """)
    private static let coefficientA = CIColorKernel(source: """
    kernel vec4 skinGuideA(__sample mean, __sample correlation, float epsilon) {
        float weight = max(mean.a, 1.0e-20);
        vec3 average = mean.rgb / weight;
        vec3 variance = max(correlation.rgb / weight - average * average, vec3(0.0));
        return vec4(variance / (variance + vec3(epsilon)) * mean.a, mean.a);
    }
    """)
    private static let coefficientB = CIColorKernel(source: """
    kernel vec4 skinGuideB(__sample mean, __sample slope) {
        return vec4(mean.rgb * (vec3(1.0) - slope.rgb / max(slope.a, 1.0e-20)), mean.a);
    }
    """)
    private static let reconstruction = CIColorKernel(source: """
    kernel vec4 skinGuideReconstruct(__sample image, __sample slope, __sample intercept) {
        if (image.a <= 0.0) return vec4(0.0);
        return vec4(image.rgb * slope.rgb / max(slope.a, 1.0e-20)
                    + intercept.rgb / max(intercept.a, 1.0e-20) * image.a, image.a);
    }
    """)

}
