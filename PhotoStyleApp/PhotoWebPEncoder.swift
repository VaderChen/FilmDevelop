import CoreGraphics
import Foundation
import PhotoWebP

/// WebP is an 8-bit delivery format. All scene rendering and tone mapping must
/// finish before this boundary; the source image is never mutated.
enum PhotoWebPEncoder {
    static func encode(_ cgImage: CGImage, quality: Float = 95) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              width <= Int(WEBP_MAX_DIMENSION), height <= Int(WEBP_MAX_DIMENSION),
              quality.isFinite,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let stride = width * 4
        var rgba = [UInt8](repeating: 0, count: stride * height)
        return rgba.withUnsafeMutableBytes { buffer -> Data? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: stride, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            // Quartz stores premultiplied RGBA; libwebp's RGBA API needs straight
            // alpha. Without this step translucent edges acquire dark fringes.
            for index in Swift.stride(from: 0, to: buffer.count, by: 4) {
                let alpha = UInt16(pixels[index + 3])
                guard alpha < 255 else { continue }
                for channel in 0..<3 {
                    pixels[index + channel] = alpha == 0 ? 0 : UInt8(min(255,
                        (UInt16(pixels[index + channel]) * 255 + alpha / 2) / alpha))
                }
            }
            var encoded: UnsafeMutablePointer<UInt8>?
            let count = WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(stride),
                                       min(100, max(0, quality)), &encoded)
            guard count > 0, let encoded else { return nil }
            defer { WebPFree(encoded) }
            return Data(bytes: encoded, count: count)
        }
    }
}
