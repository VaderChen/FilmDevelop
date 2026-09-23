import CoreImage

enum PhotoFastGuidedFilter {
    private static let squaredKernel = CIColorKernel(source: """
    kernel vec4 guidedSquared(__sample source) {
        float value = source.r * source.r;
        return vec4(value, value, value, source.a);
    }
    """)

    private static let coefficientsKernel = CIColorKernel(source: """
    kernel vec4 guidedCoefficients(
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

    private static let reconstructionKernel = CIColorKernel(source: """
    kernel vec4 guidedReconstruction(__sample guide, __sample coefficients) {
        float value = coefficients.r * guide.r + coefficients.g;
        return vec4(value, value, value, guide.a);
    }
    """)

    static func smooth(
        _ image: CIImage,
        maximumSampleShortEdge: CGFloat = 256,
        epsilon: Float = 0.0025
    ) -> CIImage {
        let extent = image.extent
        let shortEdge = max(min(extent.width, extent.height), 1)
        let scale = min(maximumSampleShortEdge / shortEdge, 0.5)
        let sampled = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
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

        let averagedCoefficients = boxBlur(coefficients, radius: radius)
        let upsampledCoefficients = averagedCoefficients
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
        return reconstructionKernel.apply(
            extent: extent,
            arguments: [image, upsampledCoefficients]
        )?.cropped(to: extent) ?? fallback(image)
    }

    private static func boxBlur(_ image: CIImage, radius: CGFloat) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [
                kCIInputRadiusKey: radius
            ])
            .cropped(to: image.extent)
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
