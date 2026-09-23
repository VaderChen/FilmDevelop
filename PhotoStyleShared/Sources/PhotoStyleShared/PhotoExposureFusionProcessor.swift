import CoreImage

public enum PhotoExposureFusionProcessor {
    private static let absoluteKernel = CIColorKernel(source: """
    kernel vec4 absoluteLaplacian(__sample source) {
        float value = abs(source.r);
        return vec4(value, value, value, source.a);
    }
    """)

    private static let qualityWeightKernel = CIColorKernel(source: """
    kernel vec4 exposureQualityWeight(__sample source, __sample contrast) {
        vec3 color = clamp(source.rgb, 0.0, 1.0);
        float mean = (color.r + color.g + color.b) / 3.0;
        vec3 centered = color - vec3(mean);
        float saturation = sqrt(max(dot(centered, centered) / 3.0, 0.0));
        vec3 exposureDelta = color - vec3(0.5);
        float wellExposed = exp(-dot(exposureDelta, exposureDelta) / 0.16);
        float weight = max(source.a, 0.0)
            * (0.01 + max(contrast.r, 0.0))
            * (0.01 + saturation)
            * (0.001 + wellExposed);
        return vec4(weight, weight, weight, 1.0);
    }
    """)

    private static let normalizedWeightsKernel = CIColorKernel(source: """
    kernel vec4 normalizeExposureWeights(
        __sample dark,
        __sample neutral,
        __sample bright
    ) {
        float total = max(dark.r + neutral.r + bright.r, 0.000001);
        return vec4(dark.r / total, neutral.r / total, bright.r / total, 1.0);
    }
    """)

    private static let laplacianKernel = CIColorKernel(source: """
    kernel vec4 exposureLaplacian(__sample current, __sample expanded) {
        return vec4(current.rgb - expanded.rgb, current.a);
    }
    """)

    private static let weightedLevelKernel = CIColorKernel(source: """
    kernel vec4 fusePyramidLevel(
        __sample dark,
        __sample neutral,
        __sample bright,
        __sample darkWeight,
        __sample neutralWeight,
        __sample brightWeight
    ) {
        float darkAmount = max(darkWeight.r, 0.0);
        float neutralAmount = max(neutralWeight.r, 0.0);
        float brightAmount = max(brightWeight.r, 0.0);
        float total = max(darkAmount + neutralAmount + brightAmount, 0.000001);
        vec3 color = (
            dark.rgb * darkAmount
            + neutral.rgb * neutralAmount
            + bright.rgb * brightAmount
        ) / total;
        float alpha = (
            dark.a * darkAmount
            + neutral.a * neutralAmount
            + bright.a * brightAmount
        ) / total;
        return vec4(color, alpha);
    }
    """)

    private static let collapseKernel = CIColorKernel(source: """
    kernel vec4 collapseExposurePyramid(__sample detail, __sample expanded) {
        return vec4(detail.rgb + expanded.rgb, max(detail.a, expanded.a));
    }
    """)

    private static let finalKernel = CIColorKernel(source: """
    kernel vec4 finalizeExposureFusion(__sample source) {
        return vec4(clamp(source.rgb, 0.0, 1.0), clamp(source.a, 0.0, 1.0));
    }
    """)

    private static let laplacianWeights: CIVector = {
        let values: [CGFloat] = [
            0, 1, 0,
            1, -4, 1,
            0, 1, 0
        ]
        return values.withUnsafeBufferPointer { buffer in
            CIVector(values: buffer.baseAddress!, count: buffer.count)
        }
    }()

    public static func fuse(
        dark: CIImage,
        neutral: CIImage,
        bright: CIImage
    ) -> CIImage? {
        let originalExtent = neutral.extent
        guard !originalExtent.isEmpty,
              let absoluteKernel,
              let qualityWeightKernel,
              let normalizedWeightsKernel,
              let laplacianKernel,
              let weightedLevelKernel,
              let collapseKernel,
              let finalKernel else {
            return nil
        }

        let images = normalizedImages(
            dark: dark,
            neutral: neutral,
            bright: bright,
            extent: originalExtent
        )
        let levelCount = pyramidLevelCount(for: images.neutral.extent)
        guard let weights = normalizedWeights(
            dark: images.dark,
            neutral: images.neutral,
            bright: images.bright,
            absoluteKernel: absoluteKernel,
            qualityWeightKernel: qualityWeightKernel,
            normalizedWeightsKernel: normalizedWeightsKernel
        ) else {
            return nil
        }

        let darkGaussian = gaussianPyramid(for: images.dark, levelCount: levelCount)
        let neutralGaussian = gaussianPyramid(for: images.neutral, levelCount: levelCount)
        let brightGaussian = gaussianPyramid(for: images.bright, levelCount: levelCount)
        guard let darkLaplacian = laplacianPyramid(
            from: darkGaussian,
            kernel: laplacianKernel
        ), let neutralLaplacian = laplacianPyramid(
            from: neutralGaussian,
            kernel: laplacianKernel
        ), let brightLaplacian = laplacianPyramid(
            from: brightGaussian,
            kernel: laplacianKernel
        ) else {
            return nil
        }

        let darkWeightPyramid = gaussianPyramid(for: weights.dark, levelCount: levelCount)
        let neutralWeightPyramid = gaussianPyramid(for: weights.neutral, levelCount: levelCount)
        let brightWeightPyramid = gaussianPyramid(for: weights.bright, levelCount: levelCount)
        var fusedLevels: [CIImage] = []
        fusedLevels.reserveCapacity(levelCount)
        for level in 0..<levelCount {
            let extent = neutralLaplacian[level].extent
            guard let fused = weightedLevelKernel.apply(
                extent: extent,
                arguments: [
                    darkLaplacian[level],
                    neutralLaplacian[level],
                    brightLaplacian[level],
                    darkWeightPyramid[level],
                    neutralWeightPyramid[level],
                    brightWeightPyramid[level]
                ]
            ) else {
                return nil
            }
            fusedLevels.append(fused.cropped(to: extent))
        }

        guard var collapsed = fusedLevels.last else { return nil }
        if fusedLevels.count > 1 {
            for level in stride(from: fusedLevels.count - 2, through: 0, by: -1) {
                let extent = fusedLevels[level].extent
                let expanded = upsampled(collapsed, to: extent)
                guard let combined = collapseKernel.apply(
                    extent: extent,
                    arguments: [fusedLevels[level], expanded]
                ) else {
                    return nil
                }
                collapsed = combined.cropped(to: extent)
            }
        }

        guard let finalized = finalKernel.apply(
            extent: images.neutral.extent,
            arguments: [collapsed]
        ) else {
            return nil
        }
        return finalized
            .transformed(
                by: CGAffineTransform(
                    translationX: originalExtent.minX,
                    y: originalExtent.minY
                )
            )
            .cropped(to: originalExtent)
    }

    static func pyramidLevelCount(for extent: CGRect) -> Int {
        var shortestEdge = floor(min(extent.width, extent.height))
        var levelCount = 1
        while shortestEdge >= 32, levelCount < 6 {
            shortestEdge = floor(shortestEdge / 2)
            levelCount += 1
        }
        return levelCount
    }

    private static func normalizedImages(
        dark: CIImage,
        neutral: CIImage,
        bright: CIImage,
        extent: CGRect
    ) -> (dark: CIImage, neutral: CIImage, bright: CIImage) {
        let fittedDark = dark
            .cropped(to: extent)
            .applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: neutral
            ])
            .cropped(to: extent)
        let fittedBright = bright
            .cropped(to: extent)
            .applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: neutral
            ])
            .cropped(to: extent)
        let transform = CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        )
        return (
            fittedDark.transformed(by: transform),
            neutral.cropped(to: extent).transformed(by: transform),
            fittedBright.transformed(by: transform)
        )
    }

    private static func normalizedWeights(
        dark: CIImage,
        neutral: CIImage,
        bright: CIImage,
        absoluteKernel: CIColorKernel,
        qualityWeightKernel: CIColorKernel,
        normalizedWeightsKernel: CIColorKernel
    ) -> (dark: CIImage, neutral: CIImage, bright: CIImage)? {
        let darkContrast = contrastMap(for: dark, absoluteKernel: absoluteKernel)
        let neutralContrast = contrastMap(for: neutral, absoluteKernel: absoluteKernel)
        let brightContrast = contrastMap(for: bright, absoluteKernel: absoluteKernel)
        guard let rawDarkWeight = qualityWeightKernel.apply(
            extent: dark.extent,
            arguments: [dark, darkContrast]
        ), let rawNeutralWeight = qualityWeightKernel.apply(
            extent: neutral.extent,
            arguments: [neutral, neutralContrast]
        ), let rawBrightWeight = qualityWeightKernel.apply(
            extent: bright.extent,
            arguments: [bright, brightContrast]
        ) else {
            return nil
        }
        let darkWeight = smoothedWeight(rawDarkWeight)
        let neutralWeight = smoothedWeight(rawNeutralWeight)
        let brightWeight = smoothedWeight(rawBrightWeight)
        guard let packed = normalizedWeightsKernel.apply(
            extent: neutral.extent,
            arguments: [darkWeight, neutralWeight, brightWeight]
        ) else {
            return nil
        }
        return (
            channel(from: packed, index: 0),
            channel(from: packed, index: 1),
            channel(from: packed, index: 2)
        )
    }

    private static func smoothedWeight(_ image: CIImage) -> CIImage {
        image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 2.0
            ])
            .cropped(to: image.extent)
    }

    private static func contrastMap(
        for image: CIImage,
        absoluteKernel: CIColorKernel
    ) -> CIImage {
        let luminance = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let laplacian = luminance
            .clampedToExtent()
            .applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": laplacianWeights,
                "inputBias": 0
            ])
            .cropped(to: image.extent)
        let absolute = absoluteKernel.apply(
            extent: image.extent,
            arguments: [laplacian]
        )?.cropped(to: image.extent) ?? luminance
        return absolute
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 1.0
            ])
            .cropped(to: image.extent)
    }

    private static func channel(from packed: CIImage, index: Int) -> CIImage {
        let vector = switch index {
        case 0: CIVector(x: 1, y: 0, z: 0, w: 0)
        case 1: CIVector(x: 0, y: 1, z: 0, w: 0)
        default: CIVector(x: 0, y: 0, z: 1, w: 0)
        }
        return packed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": vector,
            "inputGVector": vector,
            "inputBVector": vector,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: packed.extent)
    }

    private static func gaussianPyramid(
        for image: CIImage,
        levelCount: Int
    ) -> [CIImage] {
        var levels = [image]
        levels.reserveCapacity(levelCount)
        while levels.count < levelCount {
            levels.append(downsampled(levels[levels.count - 1]))
        }
        return levels
    }

    private static func laplacianPyramid(
        from gaussian: [CIImage],
        kernel: CIColorKernel
    ) -> [CIImage]? {
        guard let finalLevel = gaussian.last else { return nil }
        var levels: [CIImage] = []
        levels.reserveCapacity(gaussian.count)
        if gaussian.count > 1 {
            for level in 0..<(gaussian.count - 1) {
                let current = gaussian[level]
                let expanded = upsampled(gaussian[level + 1], to: current.extent)
                guard let detail = kernel.apply(
                    extent: current.extent,
                    arguments: [current, expanded]
                ) else {
                    return nil
                }
                levels.append(detail.cropped(to: current.extent))
            }
        }
        levels.append(finalLevel)
        return levels
    }

    private static func downsampled(_ image: CIImage) -> CIImage {
        let targetExtent = CGRect(
            x: 0,
            y: 0,
            width: max(floor(image.extent.width / 2), 1),
            height: max(floor(image.extent.height / 2), 1)
        )
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 1.0
            ])
            .cropped(to: image.extent)
        return blurred
            .transformed(
                by: CGAffineTransform(
                    scaleX: targetExtent.width / image.extent.width,
                    y: targetExtent.height / image.extent.height
                )
            )
            .cropped(to: targetExtent)
    }

    private static func upsampled(_ image: CIImage, to extent: CGRect) -> CIImage {
        image
            .clampedToExtent()
            .transformed(
                by: CGAffineTransform(
                    scaleX: extent.width / image.extent.width,
                    y: extent.height / image.extent.height
                )
            )
            .cropped(to: extent)
    }
}
