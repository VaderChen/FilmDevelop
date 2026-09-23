import CoreImage
import CoreVideo
#if canImport(Vision)
import Vision
#endif

public enum PhotoSubjectMaskGenerator {
    public static var isAvailable: Bool {
        #if canImport(Vision)
        if #available(macOS 12.0, *) { return true }
        #endif
        return false
    }

    public static func makeMask(from image: CIImage) -> CIImage? {
        let extent = image.extent
        #if canImport(Vision)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let renderContext = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        guard let cgImage = renderContext.createCGImage(image, from: extent) else {
            return nil
        }

        if #available(macOS 14.0, *) {
            if let personMask = makePersonInstanceMask(from: cgImage, extent: extent) {
                return personMask
            }

            if let foregroundMask = makeForegroundInstanceMask(from: cgImage, extent: extent) {
                return foregroundMask
            }
        }

        if #available(macOS 12.0, *) {
            return makePersonSegmentationMask(from: cgImage, extent: extent)
        }

        return nil
        #else
        return nil
        #endif
    }

    #if canImport(Vision)
    @available(macOS 14.0, *)
    private static func makePersonInstanceMask(from cgImage: CGImage, extent: CGRect) -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()

        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                return nil
            }

            if let scaledBuffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            ) {
                return fitMask(CIImage(cvPixelBuffer: scaledBuffer), to: extent)
            }

            guard let buffer = copiedBinaryMaskBuffer(from: observation.instanceMask) else {
                return nil
            }
            return fitMask(CIImage(cvPixelBuffer: buffer), to: extent)
        } catch {
            return nil
        }
    }

    @available(macOS 14.0, *)
    private static func makeForegroundInstanceMask(from cgImage: CGImage, extent: CGRect) -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                return nil
            }

            if let scaledBuffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            ) {
                return fitMask(CIImage(cvPixelBuffer: scaledBuffer), to: extent)
            }

            guard let buffer = copiedBinaryMaskBuffer(from: observation.instanceMask) else {
                return nil
            }
            return fitMask(CIImage(cvPixelBuffer: buffer), to: extent)
        } catch {
            return nil
        }
    }

    @available(macOS 12.0, *)
    private static func makePersonSegmentationMask(from cgImage: CGImage, extent: CGRect) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else {
                return nil
            }

            let mask = CIImage(cvPixelBuffer: buffer)
            return fitMask(mask, to: extent)
        } catch {
            return nil
        }
    }

    public static func fitMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let scaleX = extent.width / max(mask.extent.width, 1)
        let scaleY = extent.height / max(mask.extent.height, 1)
        return mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: extent.minX - mask.extent.minX * scaleX,
                y: extent.minY - mask.extent.minY * scaleY
            ))
            .cropped(to: extent)
    }

    static func copiedBinaryMaskBuffer(from sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(sourceBuffer) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }

        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: false
        ] as CFDictionary
        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes,
            &destinationBuffer
        ) == kCVReturnSuccess,
        let destinationBuffer else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly) }

        guard CVPixelBufferLockBaseAddress(destinationBuffer, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(destinationBuffer, []) }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourceBuffer),
              let destinationBaseAddress = CVPixelBufferGetBaseAddress(destinationBuffer) else {
            return nil
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destinationBuffer)
        for row in 0..<height {
            let sourceRow = sourceBaseAddress
                .advanced(by: row * sourceBytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            let destinationRow = destinationBaseAddress
                .advanced(by: row * destinationBytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            destinationRow.initialize(repeating: 0, count: destinationBytesPerRow)
            for column in 0..<width {
                destinationRow[column] = sourceRow[column] == 0 ? 0 : 255
            }
        }

        return destinationBuffer
    }
    #endif
}
