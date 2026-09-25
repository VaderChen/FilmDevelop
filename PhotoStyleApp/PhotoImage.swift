import AppKit
import PhotoStyleShared
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

enum PhotoExportFormat: String, CaseIterable {
    case jpeg, png, webp, tiff

    var supportedBitDepths: [Int] { self == .png || self == .tiff ? [8, 16] : [8] }
    var defaultBitDepth: Int { self == .tiff ? 16 : 8 }
    var displayName: String { rawValue.uppercased() }
    var fileExtensions: [String] {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .png: return ["png"]
        case .webp: return ["webp"]
        case .tiff: return ["tif", "tiff"]
        }
    }
    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .tiff: return .tiff
        }
    }
}

/// A photo is measured in pixels, independent of a window's Retina backing scale.
/// Decode EXIF orientation once so previews, crops and exports share coordinates.
struct PhotoImage {
    static let previewMaxPixel: CGFloat = 1024
    let cgImage: CGImage?
    /// Scene-referred RAW needs display mapping once. Storage depth is independent.
    let requiresRAWDisplayMapping: Bool
    var scale: CGFloat { 1 }
    var imageOrientation: CGImagePropertyOrientation { .up }
    var size: CGSize {
        CGSize(width: cgImage?.width ?? 0, height: cgImage?.height ?? 0)
    }

    private static let context = PhotoImageRenderPrecision.makeContext()

    init(cgImage: CGImage, scale: CGFloat = 1, orientation: CGImagePropertyOrientation = .up,
         requiresRAWDisplayMapping: Bool = false) {
        self.requiresRAWDisplayMapping = requiresRAWDisplayMapping
        // Materialize integer/decoder-backed images into a stable FP32 bitmap.
        // This also avoids Core Image's direct JPEG-provider → RGBAf conversion,
        // which can produce invalid samples on macOS for some decoded layouts.
        guard let bitmap = Self.floatingBitmap(cgImage) else {
            self.cgImage = nil
            return
        }
        if orientation == .up {
            self.cgImage = bitmap
        } else {
            let oriented = CIImage(cgImage: bitmap).oriented(orientation)
            self.cgImage = Self.context.createCGImage(
                oriented, from: oriented.extent,
                format: .RGBAf,
                colorSpace: bitmap.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            ) ?? bitmap
        }
    }

    private static func floatingBitmap(_ image: CGImage) -> CGImage? {
        if image.bitsPerComponent == 32 && image.bitmapInfo.contains(.floatComponents) { return image }
        let colorSpace = workingColorSpace(for: image)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 32, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func workingColorSpace(for image: CGImage?) -> CGColorSpace {
        if let source = image?.colorSpace, source.model == .rgb,
           let linear = CGColorSpaceCreateExtendedLinearized(source) { return linear }
        return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    }

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        self.init(cgImage: image, orientation: orientation)
        guard cgImage != nil else { return nil }
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        encodedData(format: .jpeg, bitDepth: 8, quality: compressionQuality)
    }

    func pngData() -> Data? { encodedData(format: .png, bitDepth: PhotoExportFormat.png.defaultBitDepth) }

    func encodedData(format: PhotoExportFormat, bitDepth: Int, quality: CGFloat = 0.95) -> Data? {
        guard format.supportedBitDepths.contains(bitDepth), quality.isFinite, let cgImage else { return nil }
        // Quantize only at the output boundary; working images remain Float32.
        let bounds = CGRect(origin: .zero, size: size)
        var image = CIImage(cgImage: cgImage)
        let opaquePNG = format == .png && bitDepth == 8
        if opaquePNG {
            // Match the black preview background when rotation leaves transparent edges.
            image = image.composited(over: CIImage(color: .black)).cropped(to: bounds)
        }
        let pixelFormat: CIFormat = opaquePNG ? .RGBX8 : (bitDepth == 16 ? .RGBA16 : .RGBA8)
        guard let bitmap = Self.context.createCGImage(
            image, from: bounds, format: pixelFormat,
            colorSpace: format == .jpeg || format == .webp || opaquePNG
                ? CGColorSpace(name: CGColorSpace.sRGB)!
                : (cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!),
            deferred: false
        ) else { return nil }
        if format == .webp {
            return PhotoWebPEncoder.encode(bitmap, quality: Float(min(1, max(0, quality)) * 100))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap, [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality)),
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Internal lossless cache, including scene-linear values above 1 and negative values.
    func floatingPointTIFFData() -> Data? {
        guard let cgImage else { return nil }
        return Self.context.tiffRepresentation(
            of: CIImage(cgImage: cgImage), format: .RGBAf,
            colorSpace: cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            options: [:]
        )
    }

    func rotatedForCrop(degrees: Double) -> PhotoImage {
        guard degrees.isFinite, abs(degrees) > 0.000001, let cgImage else { return self }
        let source = CIImage(cgImage: cgImage)
        let transform = PhotoCropCalculator.rotationTransform(in: source.extent, clockwiseDegrees: degrees)
        let rotated = source.transformed(by: transform).cropped(to: source.extent)
        return PhotoImageRenderPrecision.renderedImage(from: rotated, context: Self.context, preserving: self) ?? self
    }

    func cropped(to rect: CGRect) -> PhotoImage {
        guard let image = cgImage?.cropping(to: rect.integral) else { return self }
        return PhotoImage(cgImage: image, requiresRAWDisplayMapping: requiresRAWDisplayMapping)
    }

    func resized(to target: CGSize) -> PhotoImage {
        guard let cgImage, size.width > 0, size.height > 0 else { return self }
        let image = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(
            scaleX: max(1, target.width.rounded()) / size.width,
            y: max(1, target.height.rounded()) / size.height
        ))
        // A cached preview must own only its resized pixels. A deferred CGImage
        // retains the complete source bitmap/graph, defeating preview cache costs.
        return PhotoImageRenderPrecision.renderedImage(
            from: image, context: Self.context, highPrecision: requiresRAWDisplayMapping,
            colorSpace: cgImage.colorSpace, deferred: false
        ) ?? self
    }

    func resizedForWebPreview(maxPixel: CGFloat) -> PhotoImage {
        let longest = max(size.width, size.height)
        guard longest > maxPixel else { return self }
        let factor = maxPixel / longest
        return resized(to: CGSize(width: size.width * factor, height: size.height * factor))
    }

    /// AppKit text and frame drawing use a top-left coordinate system, like the crop UI.
    func renderedCanvas(size: CGSize, draw: (CGContext) -> Void) -> PhotoImage {
        let colorSpace = Self.workingColorSpace(for: cgImage)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil, width: max(1, Int(size.width.rounded())), height: max(1, Int(size.height.rounded())),
            bitsPerComponent: 32, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return self }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { return self }
        return PhotoImage(cgImage: output, requiresRAWDisplayMapping: requiresRAWDisplayMapping)
    }

    func draw(in rect: CGRect) {
        guard let cgImage else { return }
        NSImage(cgImage: cgImage, size: size).draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

extension CIImage {
    convenience init?(image: PhotoImage) {
        guard let cgImage = image.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }
}

enum PhotoImageRenderPrecision {
    static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false
        ]
        #if arch(arm64)
        if let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple1) {
            return CIContext(mtlDevice: device, options: options)
        }
        #endif
        // Hardware acceleration is restricted to Apple Silicon.
        return CIContext(options: options.merging([.useSoftwareRenderer: true]) { _, new in new })
    }

    static func isHighPrecision(_ image: PhotoImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return cgImage.bitsPerComponent > 8 || cgImage.bitmapInfo.contains(.floatComponents)
    }

    static func renderedImage(
        from image: CIImage, context: CIContext, highPrecision: Bool,
        colorSpace: CGColorSpace? = nil, scale: CGFloat = 1, deferred: Bool = true
    ) -> PhotoImage? {
        // The legacy highPrecision argument marks scene-referred RAW only.
        // Every working image is FP32, including those originating in 8-bit files.
        let resolvedColorSpace = colorSpace ?? CGColorSpace(
            name: highPrecision ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB
        )!
        guard let cgImage = context.createCGImage(
            image, from: image.extent, format: .RGBAf,
            colorSpace: resolvedColorSpace, deferred: deferred
        ) else { return nil }
        return PhotoImage(cgImage: cgImage, requiresRAWDisplayMapping: highPrecision)
    }

    static func renderedImage(
        from image: CIImage, context: CIContext, preserving source: PhotoImage, scale: CGFloat? = nil
    ) -> PhotoImage? {
        renderedImage(from: image, context: context, highPrecision: source.requiresRAWDisplayMapping, colorSpace: source.cgImage?.colorSpace)
    }
}
