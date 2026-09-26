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

    private static let reconstructionKernel = PhotoGPUColorKernel.make("guidedReconstruction", parameters: "__sample guide, __sample coefficients", body: """
        float value = coefficients.r * guide.r + coefficients.g;
        return vec4(value, value, value, guide.a);
    """)

    static func smooth(
        _ image: CIImage,
        maximumSampleShortEdge: CGFloat = 256,
        epsilon: Float = 0.0025,
        renderContext: CIContext? = nil
    ) -> CIImage {
        let extent = image.extent
        guard maximumSampleShortEdge.isFinite, maximumSampleShortEdge > 0,
              epsilon.isFinite, epsilon > 0 else { return image }
        let shortEdge = max(min(extent.width, extent.height), 1)
        let scale = min(maximumSampleShortEdge / shortEdge, 0.5)
        guard let sampling = PhotoFilterSampling(extent: extent, scale: scale) else { return image }
        let sampled = sampling.sample(image)
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

        let averagedCoefficients = materialize(boxBlur(coefficients, radius: radius), context: renderContext)
        let upsampledCoefficients = sampling.reconstruct(averagedCoefficients)
        return reconstructionKernel.apply(
            extent: extent,
            arguments: [image, upsampledCoefficients]
        )?.cropped(to: extent) ?? fallback(image)
    }

    /// Snapshot only the small coefficient map. Native export renders in tiles;
    /// without this boundary every tile can replay the complete guide branch.
    /// nil keeps the lazy graph for clients that render once or use another context.
    private static func materialize(_ image: CIImage, context: CIContext?) -> CIImage {
        let bounds = image.extent.integral
        guard let context, bounds.width > 0, bounds.height > 0,
              bounds.width * bounds.height <= 1_048_576 else { return image }
        let rowBytes = Int(bounds.width) * 16
        var data = Data(count: rowBytes * Int(bounds.height))
        data.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: rowBytes,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        // These are slope/intercept DATA, not RGB: do not color-convert them.
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: bounds.size,
                       format: .RGBAf, colorSpace: nil)
            .transformed(by: .init(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: image.extent)
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
