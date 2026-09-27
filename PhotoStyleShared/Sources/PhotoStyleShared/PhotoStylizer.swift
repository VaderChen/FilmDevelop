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
        // The decoded pixels must come from the same snapshot, including RAW
        // detection. A second URL read can otherwise observe a replaced file.
        let data = try Data(contentsOf: inputURL)
        guard let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let outputSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PhotoStylizerError.renderFailed
        }
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: linearSpace,
            .outputColorSpace: outputSpace
        ])
        let sourceType = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) }
            .flatMap { UTType($0 as String) }
        let hintedType = UTType(filenameExtension: inputURL.pathExtension)
        let isRAW = sourceType?.conforms(to: .rawImage) == true
            || hintedType?.conforms(to: .rawImage) == true
        let input: CIImage
        if isRAW {
            guard let filter = PhotoRAWDecoder.makeSceneLinearFilter(data: data, identifierHint: hintedType?.identifier),
                  let image = filter.outputImage,
                  image.extent.minX.isFinite, image.extent.minY.isFinite,
                  image.extent.width.isFinite, image.extent.height.isFinite,
                  !image.extent.isEmpty,
                  // Finish native-resolution decoding before downstream branches
                  // sample at different scales. Never accept an embedded JPEG as
                  // ordinary scene-referred RAW in this file-based renderer.
                  let bitmap = context.createCGImage(image, from: image.extent,
                      format: .RGBAf, colorSpace: linearSpace, deferred: false) else {
                throw PhotoStylizerError.imageLoadFailed(inputURL)
            }
            input = CIImage(cgImage: bitmap)
        } else {
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw PhotoStylizerError.imageLoadFailed(inputURL)
            }
            input = image
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let rendered = render(input: input, plan: plan)
        // The CIImage API retains extended scene RGB for further processing.
        // This PNG API is an SDR endpoint, so consume RAW headroom once here.
        let styled = isRAW ? PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(rendered) : rendered
        let extent = styled.extent

        guard let cgImage = context.createCGImage(styled, from: extent, format: .RGBA16, colorSpace: outputSpace) else {
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
        // 感光雜訊先清理，再模擬乳劑顆粒，避免兩個控制項互相抵消。
        let cleanedInput = PhotoToneZoneProcessor.applyDenoise(to: input,
            masks: PhotoToneMasks(input: input, profile: .balanced),
            amount: normalized(plan.postProcessing.denoise), strength: strength)
        let digitalInput = PhotoPlanToneProcessor.apply(to: cleanedInput, toneZones: plan.toneZones,
            masks: PhotoToneMasks(input: cleanedInput, profile: .balanced), strength: strength, components: [.exposure, .mapping])
        let exposedInput = PhotoFilmEffectsProcessor.applyExposure(to: digitalInput, effects: plan.filmEffects, strength: strength)
        let developed = PhotoFilmExposureProcessor.apply(to: exposedInput, effects: plan.filmEffects,
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
            strength: strength,
            components: PhotoPlanToneComponents.all.subtracting(.exposure)
        )
        var printEffects = plan.filmEffects
        printEffects.clearPrintExposure()
        styled = PhotoFilmEffectsProcessor.applyPrint(to: styled, effects: printEffects, strength: strength)
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
