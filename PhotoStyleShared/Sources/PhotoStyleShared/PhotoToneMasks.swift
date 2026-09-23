import CoreImage

public enum PhotoToneRegion: Sendable {
    case shadows
    case midtones
    case highlights
}

public enum PhotoToneMaskProfile: Sendable {
    case layered
    case balanced
}

public struct PhotoToneMasks: Sendable {
    private static let packedMaskKernel = CIColorKernel(source: """
    float toneGaussian(float stops, float negativeSigma, float positiveSigma) {
        float sigma = stops < 0.0 ? negativeSigma : positiveSigma;
        float normalized = stops / max(sigma, 0.0001);
        return exp2(-0.5 * normalized * normalized);
    }

    kernel vec4 logarithmicToneMasks(
        __sample source,
        float middleGray,
        float shadowStart,
        float shadowEnd,
        float highlightStart,
        float highlightEnd,
        float negativeSigma,
        float positiveSigma
    ) {
        vec3 nonnegativeColor = max(source.rgb, vec3(0.0));
        float luminance = dot(nonnegativeColor, vec3(0.2126, 0.7152, 0.0722));
        float stops = log2(max(luminance, 0.000001) / max(middleGray, 0.0001));
        float shadowWeight = 1.0 - smoothstep(shadowStart, shadowEnd, stops);
        float midtoneWeight = toneGaussian(stops, negativeSigma, positiveSigma);
        float highlightWeight = smoothstep(highlightStart, highlightEnd, stops);
        float totalWeight = max(
            shadowWeight + midtoneWeight + highlightWeight,
            0.0001
        );
        return vec4(
            shadowWeight / totalWeight,
            midtoneWeight / totalWeight,
            highlightWeight / totalWeight,
            1.0
        );
    }
    """)

    public let shadows: CIImage
    public let midtones: CIImage
    public let highlights: CIImage

    public init(
        input: CIImage,
        profile: PhotoToneMaskProfile,
        middleGray: Double = 0.18
    ) {
        let packed = Self.packedMasks(
            from: input,
            profile: profile,
            middleGray: middleGray
        )
        let rawShadows = Self.channelMask(from: packed, region: .shadows)
        let rawMidtones = Self.channelMask(from: packed, region: .midtones)
        let rawHighlights = Self.channelMask(from: packed, region: .highlights)

        if profile == .layered {
            shadows = Self.refined(rawShadows)
            midtones = Self.refined(rawMidtones)
            highlights = Self.refined(rawHighlights)
        } else {
            shadows = rawShadows
            midtones = rawMidtones
            highlights = rawHighlights
        }
    }

    public static func mask(
        from image: CIImage,
        region: PhotoToneRegion,
        profile: PhotoToneMaskProfile,
        middleGray: Double = 0.18
    ) -> CIImage {
        let packed = packedMasks(
            from: image,
            profile: profile,
            middleGray: middleGray
        )
        let rawMask = channelMask(from: packed, region: region)
        return profile == .layered ? refined(rawMask) : rawMask
    }

    private static func packedMasks(
        from image: CIImage,
        profile: PhotoToneMaskProfile,
        middleGray: Double
    ) -> CIImage {
        let parameters = parameters(for: profile)
        let fallback = CIImage(
            color: CIColor(red: 0, green: 1, blue: 0, alpha: 1)
        ).cropped(to: image.extent)
        guard !image.extent.isEmpty,
              let packedMaskKernel,
              let output = packedMaskKernel.apply(
                extent: image.extent,
                arguments: [
                    image,
                    Float(min(max(middleGray, 0.01), 0.50)),
                    parameters.shadowStart,
                    parameters.shadowEnd,
                    parameters.highlightStart,
                    parameters.highlightEnd,
                    parameters.negativeSigma,
                    parameters.positiveSigma
                ]
              ) else {
            return fallback
        }
        return output.cropped(to: image.extent)
    }

    private static func channelMask(
        from packed: CIImage,
        region: PhotoToneRegion
    ) -> CIImage {
        let channel = switch region {
        case .shadows: CIVector(x: 1, y: 0, z: 0, w: 0)
        case .midtones: CIVector(x: 0, y: 1, z: 0, w: 0)
        case .highlights: CIVector(x: 0, y: 0, z: 1, w: 0)
        }
        return packed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": channel,
            "inputGVector": channel,
            "inputBVector": channel,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: packed.extent)
    }

    private static func refined(_ mask: CIImage) -> CIImage {
        PhotoFastGuidedFilter.smooth(
            mask,
            maximumSampleShortEdge: 256,
            epsilon: 0.0008
        ).cropped(to: mask.extent)
    }

    private static func parameters(
        for profile: PhotoToneMaskProfile
    ) -> (
        shadowStart: Float,
        shadowEnd: Float,
        highlightStart: Float,
        highlightEnd: Float,
        negativeSigma: Float,
        positiveSigma: Float
    ) {
        switch profile {
        case .layered:
            return (-1.55, 0.00, 0.55, 2.55, 0.65, 1.35)
        case .balanced:
            return (-1.35, 0.00, 0.85, 2.40, 0.70, 1.25)
        }
    }
}
