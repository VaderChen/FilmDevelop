import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(Vision)
import Vision
#endif

public enum PhotoStylizerError: LocalizedError, Sendable {
    case imageLoadFailed(URL)
    case renderFailed
    case outputFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Unable to load image: \(url.path)"
        case .renderFailed:
            return "Unable to render styled image."
        case .outputFailed(let url):
            return "Unable to write styled image: \(url.path)"
        }
    }
}

public struct PhotoStylizer: Sendable {
    public init() {}

    public func render(inputURL: URL, plan: PhotoStylePlan, outputURL: URL) throws -> URL {
        guard let input = CIImage(
            contentsOf: inputURL,
            options: [.applyOrientationProperty: true]
        ) else {
            throw PhotoStylizerError.imageLoadFailed(inputURL)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let styled = render(input: input, plan: plan)
        let extent = styled.extent

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])

        guard let cgImage = context.createCGImage(styled, from: extent, format: .RGBA16, colorSpace: colorSpace) else {
            throw PhotoStylizerError.renderFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoStylizerError.outputFailed(outputURL)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoStylizerError.outputFailed(outputURL)
        }

        return outputURL
    }

    public func render(input: CIImage, plan: PhotoStylePlan) -> CIImage {
        let input = input.oriented(forExifOrientation: 1)

        let extent = input.extent
        let strength = normalized(plan.strength)
        let isMonochrome = normalizedColorMode(plan.colorMode) == "monochrome"
        let amounts = PhotoToneZoneProcessor.resolvedGrainAmounts(globalAmount: Double(plan.postProcessing.grain) / 100 * strength,
            highlightAmount: Double(plan.toneZones.highlights.grain) / 100 * strength,
            midtoneAmount: Double(plan.toneZones.midtones.grain) / 100 * strength,
            shadowAmount: Double(plan.toneZones.shadows.grain) / 100 * strength)
        let developed = PhotoFilmExposureProcessor.apply(to: input, effects: plan.filmEffects,
            amounts: amounts, strength: strength, monochrome: isMonochrome)
        let filteredInput = isMonochrome
            ? PhotoFilmEffectsProcessor.applyMonochromeFilter(to: developed, effects: plan.filmEffects, strength: strength)
            : developed
        let baseImage = isMonochrome
            ? applyMonochrome(to: filteredInput)
            : filteredInput
        let globalAdjustedImage = applySkinEnhancement(
            to: baseImage,
            sourceForMask: input,
            extent: extent,
            whitening: normalized(plan.skinWhitening) * strength,
            smoothing: normalized(plan.skinSmoothing) * strength
        )
        let preprocessedImage = applyBackgroundBlur(
            to: globalAdjustedImage,
            sourceForMask: input,
            extent: extent,
            amount: normalized(plan.backgroundBlur) * strength
        )
        var styled = preprocessedImage
        let masks = PhotoToneMasks(input: preprocessedImage, profile: .balanced)

        styled = PhotoPlanToneProcessor.apply(
            to: styled,
            toneZones: plan.toneZones,
            masks: masks,
            strength: strength
        )
        styled = PhotoFilmEffectsProcessor.applyPrint(to: styled, effects: plan.filmEffects, strength: strength)
        styled = applyPostProcessing(
            to: styled,
            extent: extent,
            masks: masks,
            toneZones: plan.toneZones,
            postProcessing: plan.postProcessing,
            filmEffects: plan.filmEffects,
            monochrome: isMonochrome,
            strength: strength
        )

        // Keep monochrome plans achromatic even when tone adjustments include
        // warmth, tint, or a fade that would otherwise introduce a color cast.
        let output = isMonochrome ? applyMonochrome(to: styled) : styled
        return output.cropped(to: extent)
    }

    private func applyMonochrome(to image: CIImage) -> CIImage {
        PhotoImageEffectsProcessor.monochrome(image, profile: .desaturate)
    }

    private func applyBackgroundBlur(
        to image: CIImage,
        sourceForMask: CIImage,
        extent: CGRect,
        amount: Double
    ) -> CIImage {
        guard amount > 0.005,
              let personMask = makePersonMask(from: sourceForMask, extent: extent) else {
            return image
        }
        return PhotoBackgroundBlurProcessor.apply(
            to: image,
            personMask: personMask,
            amount: amount,
            faceCenter: makeFaceCenter(from: sourceForMask, extent: extent)
        )
    }

    private func applySkinEnhancement(
        to image: CIImage,
        sourceForMask: CIImage,
        extent: CGRect,
        whitening: Double,
        smoothing: Double
    ) -> CIImage {
        guard whitening > 0.005 || smoothing > 0.005 else {
            return image
        }

        let personMask = makePersonMask(from: sourceForMask, extent: extent)
        let skinMask = makeSkinMask(from: sourceForMask, personMask: personMask, extent: extent)
        return PhotoSkinEnhancementProcessor.apply(
            to: image,
            skinMask: skinMask,
            whitening: whitening,
            smoothing: smoothing,
            profile: .plan
        )
    }

    private func makeSkinMask(from image: CIImage, personMask: CIImage?, extent: CGRect) -> CIImage {
        PhotoSkinMaskGenerator.make(from: image, personMask: personMask, profile: .plan)
    }

    private func makeFaceCenter(from image: CIImage, extent: CGRect) -> CGPoint? {
        #if canImport(Vision)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        guard let cgImage = context.createCGImage(image, from: extent) else {
            return nil
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let face = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }) else {
                return nil
            }

            let box = face.boundingBox
            return CGPoint(
                x: extent.minX + box.midX * extent.width,
                y: extent.minY + box.midY * extent.height
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func makePersonMask(from image: CIImage, extent: CGRect) -> CIImage? {
        PhotoSubjectMaskGenerator.makeMask(from: image)
    }

    private func applyPostProcessing(
        to image: CIImage,
        extent: CGRect,
        masks: PhotoToneMasks,
        toneZones: PhotoStylePlan.ToneZones,
        postProcessing: PhotoStylePlan.PostProcessing,
        filmEffects: PhotoFilmEffects,
        monochrome: Bool,
        strength: Double
    ) -> CIImage {
        var output = image
        output = PhotoToneZoneProcessor.applyDenoise(
            to: output,
            masks: masks,
            amount: normalized(postProcessing.denoise),
            strength: strength
        )
        output = PhotoVignetteProcessor.applyDevignette(to: output, amount: normalized(postProcessing.devignette) * strength, profile: .plan)
        output = PhotoVignetteProcessor.applyVignette(to: output, amount: normalized(postProcessing.vignette) * strength, profile: .plan)
        return output
    }

    private func normalized(_ value: Int) -> Double {
        Double(min(100, max(0, value))) / 100.0
    }

    private func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private func radiusScale(for extent: CGRect) -> Double {
        clamped(max(extent.width, extent.height) / 1024.0, lower: 0.5, upper: 3.0)
    }

    private func normalizedColorMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func filter(_ name: String, input: CIImage, values: [String: Any]) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        for (key, value) in values {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage
    }

}
