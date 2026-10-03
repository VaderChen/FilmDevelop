import CoreImage

enum PhotoFastGuidedFilter {
    private static let squaredKernel = PhotoGPUColorKernel.make("guidedSquared", parameters: "__sample source", body: """
        float value = source.r * source.r;
        return vec4(value, value, value, source.a);
    """)

    private static let coefficientsKernel = PhotoGPUColorKernel.make("guidedCoefficients", parameters: "__sample mean, __sample correlation, float epsilon", body: """
        float variance = max(correlation.r - mean.r * mean.r, 0.0);
        float slope = variance / (variance + epsilon);
        float intercept = mean.r * (1.0 - slope);
        return vec4(slope, intercept, 0.0, 1.0);
    """)

    private static let reconstructionKernel = CIKernel(source: """
    kernel vec4 guidedReconstruction(sampler guide, sampler coefficients, vec2 origin, vec2 scale) {
        // 先在係數像素中心求值，再做雙線性插值，固定非線性統計與上採樣的順序。
        vec2 position = (destCoord() - origin) * scale - vec2(0.5);
        vec2 corner = floor(position) + vec2(0.5);
        vec2 fraction = fract(position);
        vec4 a = sample(coefficients, samplerTransform(coefficients, corner));
        vec4 b = sample(coefficients, samplerTransform(coefficients, corner + vec2(1.0, 0.0)));
        vec4 c = sample(coefficients, samplerTransform(coefficients, corner + vec2(0.0, 1.0)));
        vec4 d = sample(coefficients, samplerTransform(coefficients, corner + vec2(1.0, 1.0)));
        vec4 coefficient = mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
        vec4 source = sample(guide, samplerTransform(guide, destCoord()));
        float value = coefficient.r * source.r + coefficient.g;
        return vec4(value, value, value, source.a);
    }
    """)

    static func smooth(
        _ image: CIImage,
        maximumSampleShortEdge: CGFloat = 256,
        epsilon: Float = 0.0025,
        renderContext _: CIContext? = nil
    ) -> CIImage {
        let extent = image.extent
        guard maximumSampleShortEdge.isFinite, maximumSampleShortEdge > 0,
              epsilon.isFinite, epsilon > 0 else { return image }
        let shortEdge = max(min(extent.width, extent.height), 1)
        let scale = min(maximumSampleShortEdge / shortEdge, 0.5)
        guard let sampling = PhotoFilterSampling(extent: extent, scale: scale) else { return image }
        // 固定低解析度取樣格，再計算平方與視窗統計，避免跨縮放融合改變計算順序。
        let sampled = sampling.sample(image).insertingIntermediate()
        let sampledShortEdge = max(min(sampled.extent.width, sampled.extent.height), 1)
        let radius = min(max(sampledShortEdge / 32, 2), 8)

        guard let squaredKernel,
              let coefficientsKernel,
              let reconstructionKernel,
              let squared = squaredKernel.apply(
                extent: sampled.extent,
                arguments: [sampled]
              ) else {
            return fallback(image)
        }

        let mean = boxBlur(sampled, radius: radius)
        let correlation = boxBlur(squared, radius: radius)
        guard let coefficients = coefficientsKernel.apply(
            extent: sampled.extent,
            arguments: [mean, correlation, epsilon]
        ) else {
            return fallback(image)
        }

        let averagedCoefficients = cacheCoefficients(boxBlur(coefficients, radius: radius))
        return reconstructionKernel.apply(
            extent: extent,
            roiCallback: { index, rect in
                index == 0 ? rect : rect.applying(sampling.downsample).insetBy(dx: -1, dy: -1)
            },
            arguments: [image, averagedCoefficients.clampedToExtent(),
                CIVector(x: extent.minX, y: extent.minY),
                CIVector(x: sampling.downsample.a, y: sampling.downsample.d)]
        )?.cropped(to: extent) ?? fallback(image)
    }

    /// 係數固定在低解析度像素格後才上採樣，讓預覽、匯出與分塊渲染遵循相同算法。
    /// 只允許至多 16 MiB 的浮點係數圖常駐 GPU；省去 CPU 讀回與再次上傳。
    private static func cacheCoefficients(_ image: CIImage) -> CIImage {
        let bounds = image.extent.integral
        let cache = bounds.width > 0 && bounds.height > 0 && bounds.width * bounds.height <= 1_048_576
        return image.insertingIntermediate(cache: cache)
    }

    private static func boxBlur(_ image: CIImage, radius: CGFloat) -> CIImage {
        PhotoBoxMeanFilter.apply(image, radius: radius)
    }

    private static func fallback(_ image: CIImage) -> CIImage {
        let shortEdge = max(min(image.extent.width, image.extent.height), 1)
        let radius = min(max(shortEdge / 64, 2), 24)
        return image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: radius
            ])
            .cropped(to: image.extent)
    }
}
