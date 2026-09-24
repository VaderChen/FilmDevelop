import CoreImage
import Foundation

/// Materialize bounded numerical fields once before a downstream branch or tile
/// samples them again. Alpha may carry simulation data rather than opacity:
/// retain FP32 channels without premultiplication or a display colour transform.
enum PhotoFilmFieldSnapshot {
    static func resolve(_ image: CIImage, context: CIContext?) -> CIImage {
        guard let context else { return image }
        let bounds = image.extent.integral
        guard !bounds.isEmpty, !bounds.isInfinite,
              bounds.width <= 4096, bounds.height <= 4096 else { return image }
        let rowBytes = Int(bounds.width) * 16
        var pixels = Data(count: rowBytes * Int(bounds.height))
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: rowBytes,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        return CIImage(bitmapData: pixels, bytesPerRow: rowBytes, size: bounds.size,
                       format: .RGBAf, colorSpace: nil)
            .transformed(by: .init(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: image.extent)
    }
}
