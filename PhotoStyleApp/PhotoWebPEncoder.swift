import CoreGraphics
import Foundation
import PhotoWebP

/// WebP is an 8-bit delivery format. All scene rendering and tone mapping must
/// finish before this boundary; the source image is never mutated.
enum PhotoWebPEncoder {
    static func encode(_ cgImage: CGImage, quality: Float = 95, lossless: Bool = false, colorSpace requestedColorSpace: CGColorSpace? = nil) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              width <= Int(WEBP_MAX_DIMENSION), height <= Int(WEBP_MAX_DIMENSION),
              quality.isFinite,
              let colorSpace = requestedColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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
            let count = lossless
                ? WebPEncodeLosslessRGBA(pixels, Int32(width), Int32(height), Int32(stride), &encoded)
                : WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(stride),
                                 min(100, max(0, quality)), &encoded)
            guard count > 0, let encoded else { return nil }
            defer { WebPFree(encoded) }
            guard let profile = colorSpace.copyICCData() as Data? else { return nil }
            return embeddingICC(profile, in: Data(bytes: encoded, count: count), width: width, height: height)
        }
    }
    // Extended RIFF ordering: VP8X, ICCP, then image chunks.
    // https://developers.google.com/speed/webp/docs/riff_container
    private static func embeddingICC(_ profile: Data, in encoded: Data, width: Int, height: Int) -> Data? {
        guard encoded.count >= 12, encoded.prefix(4) == Data("RIFF".utf8),
              encoded[8..<12] == Data("WEBP".utf8) else { return nil }
        func little(_ n: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8((n >> ($0 * 8)) & 255) }) }
        func chunk(_ name: String, _ bytes: Data) -> Data {
            Data(name.utf8) + little(bytes.count, 4) + bytes + (bytes.count % 2 == 1 ? Data([0]) : Data())
        }
        var offset = 12, flags: UInt8 = 0x20, pixels = Data()
        while offset + 8 <= encoded.count {
            let count = (0..<4).reduce(0) { $0 | Int(encoded[offset + 4 + $1]) << ($1 * 8) }
            let end = offset + 8 + count + count % 2
            guard end <= encoded.count else { return nil }
            let name = String(decoding: encoded[offset..<offset+4], as: UTF8.self)
            if name == "VP8X" {
                guard count == 10 else { return nil }
                flags |= encoded[offset + 8]
            } else if name != "ICCP" {
                if name == "ALPH" || (name == "VP8L" && count >= 5 && encoded[offset + 12] & 0x10 != 0) { flags |= 0x10 }
                pixels.append(encoded[offset..<end])
            }
            offset = end
        }
        guard offset == encoded.count else { return nil }
        let header = Data([flags, 0, 0, 0]) + little(width - 1, 3) + little(height - 1, 3)
        let body = Data("WEBP".utf8) + chunk("VP8X", header) + chunk("ICCP", profile) + pixels
        return Data("RIFF".utf8) + little(body.count, 4) + body
    }

}
