import Foundation
import CoreGraphics
import PhotoRAW

/// The software option retains Float32 working storage, but LibRaw 0.22.2
/// clips its RGB16 intermediate. It must not advertise scene HDR headroom.
enum PhotoSoftwareRAWDecoder {
    static func decode(data: Data, halfSize: Bool, mappingDirectory: URL? = nil) -> PhotoImage? {
        guard let directory = mappingDirectory ?? Bundle.main.url(forResource: "RAWMapping", withExtension: nil) else { return nil }
        var pixels = PhotoRAWPixels()
        let status = data.withUnsafeBytes { bytes in
            photo_raw_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                             halfSize ? 1 : 0, directory.path, &pixels)
        }
        guard status == 0 else { return nil }
        defer { photo_raw_free(&pixels) }
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0, width <= Int.max / height / 16,
              let linear = pixels.linear_rgba, let display = pixels.display_rgb,
              let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let displaySpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // CGDataProvider owns the C allocations after this point; no full-frame copy.
        let linearData = Data(bytesNoCopy: linear, count: width * height * 16, deallocator: .free)
        let displayData = Data(bytesNoCopy: display, count: width * height * 3, deallocator: .free)
        pixels.linear_rgba = nil; pixels.display_rgb = nil
        guard let linearProvider = CGDataProvider(data: linearData as CFData),
              let displayProvider = CGDataProvider(data: displayData as CFData),
              let bitmap = CGImage(width: width, height: height, bitsPerComponent: 32,
                bitsPerPixel: 128, bytesPerRow: width * 16, space: linearSpace,
                bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: linearProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let original = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 24, bytesPerRow: width * 3, space: displaySpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: displayProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        var image = PhotoImage(cgImage: bitmap)
        image.cameraOriginal = original
        image.rawDecoderBackend = .software
        return image
    }
}
