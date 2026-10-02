import Foundation
import CoreGraphics
import PhotoRAW

/// The software option retains Float32 working storage, but LibRaw 0.22.2
/// clips its RGB16 intermediate. It must not advertise scene HDR headroom.
enum PhotoSoftwareRAWDecoder {
    /// 只補讀 RAW 拍攝資訊，不進行解馬賽克；與 Windows 使用相同 LibRaw 入口。
    static func metadata(data: Data) -> [String: Any]? {
        var value = PhotoRAWMetadata()
        let status = data.withUnsafeBytes { bytes in
            photo_raw_metadata(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value)
        }
        guard status == 0 else { return nil }
        func text<T>(_ buffer: T) -> String {
            withUnsafeBytes(of: buffer) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        var result: [String: Any] = [:]
        for (key, string) in [
            ("Make", text(value.make)), ("Model", text(value.model)),
            ("LensMake", text(value.lens_make)), ("LensModel", text(value.lens)),
            ("LensSerialNumber", text(value.lens_serial)), ("DateTimeOriginal", text(value.captured_at))
        ] where !string.isEmpty { result[key] = string }
        for (key, number) in [
            ("ISOSpeedRatings", value.iso), ("ExposureTime", value.exposure),
            ("FNumber", value.aperture), ("FocalLength", value.focal_length),
            ("FocalLenIn35mmFilm", value.focal_length_35mm)
        ] where number.isFinite && number > 0 { result[key] = number }
        return result
    }

    static func decode(data: Data, halfSize: Bool, mappingDirectory: URL? = nil) -> PhotoImage? {
        guard let directory = mappingDirectory ?? Bundle.main.url(forResource: "RAWMapping", withExtension: nil) else { return nil }
        var pixels = PhotoRAWPixels()
        let status = data.withUnsafeBytes { bytes in
            photo_raw_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                             halfSize ? 1 : 0, directory.path, &pixels)
        }
        guard status == 0 else {
            // 立即讀取同一執行緒的錯誤，不把低階錯誤吞掉。
            NSLog("內建 RAW 解析失敗：%@", String(cString: photo_raw_error()))
            return nil
        }
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
