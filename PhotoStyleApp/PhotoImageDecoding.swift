import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PhotoStyleShared

enum PhotoRAWDecodePurpose: String {
    case complete, preview, completeWithPreview
}
struct PhotoRAWDecodeRequest {
    let data: Data
    let url: URL
    let lensCorrection: Bool
    let purpose: PhotoRAWDecodePurpose
}
protocol PhotoRAWDecodeProvider {
    var route: String { get }
    func decode(_ request: PhotoRAWDecodeRequest) -> PhotoImage?
}
struct PhotoSystemRAWProvider: PhotoRAWDecodeProvider {
    let route = "mac-native-raw"
    func decode(_ request: PhotoRAWDecodeRequest) -> PhotoImage? {
        PhotoImageDecoder.decodeRAWImage(data: request.data, url: request.url, lensCorrection: request.lensCorrection)
    }
}
struct PhotoSoftwareRAWProvider: PhotoRAWDecodeProvider {
    let route = "portable-libraw"
    func decode(_ request: PhotoRAWDecodeRequest) -> PhotoImage? {
        PhotoImageDecoder.decodeSoftwareRAWImage(data: request.data, purpose: request.purpose)
    }
}
extension PhotoBackendRouter {
    static func raw(_ backend: PhotoRAWBackend) -> any PhotoRAWDecodeProvider {
        switch backend {
        case .system: return PhotoSystemRAWProvider()
        case .software: return PhotoSoftwareRAWProvider()
        }
    }
    static func decodeRAW(data: Data, url: URL, backend: PhotoRAWBackend, lensCorrection: Bool, purpose: PhotoRAWDecodePurpose = .completeWithPreview) -> PhotoImage? {
        let request = PhotoRAWDecodeRequest(data: data, url: url, lensCorrection: lensCorrection, purpose: purpose)
        if let result = raw(backend).decode(request) { return result }
        let alternative: PhotoRAWBackend = backend == .system ? .software : .system
        guard var fallback = raw(alternative).decode(request) else { return nil }
        fallback.softwareRAWFallback = backend == .software
        return fallback
    }
    static func decode(data: Data, url: URL, backend: PhotoRAWBackend, lensCorrection: Bool, purpose: PhotoRAWDecodePurpose = .completeWithPreview) -> PhotoImage? {
        PhotoImageDecoder.decode(data: data, url: url, backend: backend, lensCorrection: lensCorrection, purpose: purpose)
    }
}

/// 格式辨識、既有系統解碼及相容性處理集中於影像輸入層，不依賴 UI coordinator。
enum PhotoImageDecoder {
    private static let imageDecodeContext = PhotoImageRenderPrecision.makeContext()
    // UTI 登錄受系統版本及其他 App 影響，已知 RAW 副檔名仍須走感光資料解碼。
    private static let rawExtensions = Set("3fr arw cr2 cr3 crw dng erf fff gpr iiq kdc mef mos mrw nef nrw orf pef raf raw rw2 rwl sr2 srf srw x3f".split(separator: " ").map(String.init))
    static func decode(data: Data, url: URL, backend: PhotoRAWBackend, lensCorrection: Bool, purpose: PhotoRAWDecodePurpose = .completeWithPreview) -> PhotoImage? {
        let correctLens = lensCorrection
        let selectedBackend = backend
        let isRAWFile = rawExtensions.contains(url.pathExtension.lowercased())
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            // Nikon NEF can be reported as public.tiff with a tiny embedded JPEG
            // at index zero. Decode camera RAW before accepting that raster image.
            if sourceContainsRAWData(source) || isRAWFile {
                return PhotoBackendRouter.decodeRAW(data: data, url: url, backend: selectedBackend, lensCorrection: correctLens, purpose: purpose)
            }
            if let image = decodeImageSource(source) {
                return image
            }
        }

        if let image = PhotoBackendRouter.decodeRAW(data: data, url: url, backend: selectedBackend, lensCorrection: correctLens, purpose: purpose) { return image }
        if isRAWFile { return nil }

        if let image = PhotoImage(data: data) {
            return image
        }

        // Decode only the coordinated snapshot: rereading the URL can display different bytes
        // from the content identifier and the copy persisted for the next launch.
        let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true])
        guard let ciImage else { return nil }
        return PhotoImageRenderPrecision.renderedImage(
            from: ciImage,
            context: Self.imageDecodeContext,
            highPrecision: false,
            scale: 1
        )
    }

    static func decodeSoftwareRAWImage(data: Data, purpose: PhotoRAWDecodePurpose = .completeWithPreview) -> PhotoImage? {
        if purpose == .preview, let dimensions = PhotoSoftwareRAWDecoder.dimensions(data: data),
           var half = PhotoSoftwareRAWDecoder.decode(data: data, halfSize: true),
           let linear = half.cgImage, let display = half.cameraOriginal {
            // 與舊版 processingPreview 使用同一份 LibRaw 半尺寸感光解碼。
            half.softwareRAWPreview = (linear, display)
            half.decodedSourceSize = dimensions
            return half
        }
        guard var full = PhotoSoftwareRAWDecoder.decode(data: data, halfSize: false) else { return nil }
        if purpose != .complete {
            guard let half = PhotoSoftwareRAWDecoder.decode(data: data, halfSize: true),
                  let linear = half.cgImage, let display = half.cameraOriginal else { return nil }
            full.softwareRAWPreview = (linear, display)
        }
        return full
    }

    private static func sourceContainsRAWData(_ source: CGImageSource) -> Bool {
        guard let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    static func decodeRAWImage(data: Data, url: URL, lensCorrection: Bool) -> PhotoImage? {
        let identifierHint = UTType(filenameExtension: url.pathExtension)?.identifier
        let rawFilter = PhotoRAWDecoder.makeSceneLinearFilter(
            data: data,
            identifierHint: identifierHint,
            lensCorrectionEnabled: lensCorrection
        )
        // Malformed files can return nil metadata despite the SDK's nonnull annotation.
        // KVC keeps that Objective-C nil optional instead of trapping during Swift bridging.
        guard let rawFilter,
              let rawProperties = rawFilter.value(forKey: "properties") as? NSDictionary,
              let output = rawFilter.outputImage,
              output.extent.minX.isFinite,
              output.extent.minY.isFinite,
              output.extent.width.isFinite,
              output.extent.height.isFinite,
              !output.extent.isEmpty else {
            return nil
        }

        let properties = rawProperties
        let profileName = properties[kCGImagePropertyProfileName] as? String
        let colorSpaceName = profileName?.localizedCaseInsensitiveContains("P3") == true
            ? CGColorSpace.extendedLinearDisplayP3
            : CGColorSpace.extendedLinearSRGB
        guard var decoded = PhotoImageRenderPrecision.renderedImage(
            from: output,
            context: Self.imageDecodeContext,
            highPrecision: true,
            colorSpace: CGColorSpace(name: colorSpaceName),
            // Finish RAW decoding before any preview, statistics or development
            // branch resamples it. A deferred RAW provider can replay decoding
            // and return corrupt tiles when those branches request different scales.
            scale: 1,
            deferred: false
        ) else { return nil }
        // CIRAWFilter can succeed yet return only near-zero pixels for a NEF.
        // Require contradictory, visible camera-JPEG content before replacing
        // a dark RAW: real black frames and ordinary underexposure stay RAW.
        if Self.rawBitmapIsCollapsed(decoded),
           let bitmap = PhotoRAWThumbnail.make(from: data, maxPixel: Int(max(output.extent.width, output.extent.height))),
           bitmap.width >= 1024, bitmap.height >= 1024 {
            // 內嵌 JPEG 只能用於列表／載入提示；不可冒充 RAW 編輯來源。
            if Self.rawPreviewHasVisibleContent(PhotoImage(cgImage: bitmap)) { return nil }
        }
        // 另存預設 RAW 顯影，保留每張照片的基準曝光、色調增強與白平衡。
        // 不使用內嵌 JPEG 代替 RAW，也不把顯示曲線灌入底片的線性輸入。
        let cameraFilter = CIRAWFilter(imageData: data, identifierHint: identifierHint)
        if let cameraFilter, cameraFilter.isLensCorrectionSupported {
            cameraFilter.isLensCorrectionEnabled = lensCorrection
        }
        if let cameraFilter,
           let cameraOutput = cameraFilter.outputImage,
           cameraOutput.extent == output.extent,
           let cameraImage = PhotoImageRenderPrecision.renderedImage(
               from: cameraOutput, context: Self.imageDecodeContext, highPrecision: false,
               colorSpace: CGColorSpace(name: colorSpaceName), scale: 1, deferred: false) {
            decoded.cameraOriginal = cameraImage.cgImage
        }
        decoded.rawDecoderBackend = .system
        return decoded
    }

    /// Inspect stable FP32 storage directly: no second RAW decode, resampling or GPU allocation.
    private static func rawBitmapSampleRange(_ image: PhotoImage) -> (Float, Float)? {
        guard let bitmap = image.cgImage, bitmap.bitsPerComponent == 32,
              bitmap.bitsPerPixel == 128, bitmap.bitmapInfo.contains(.floatComponents),
              let data = bitmap.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              bitmap.bytesPerRow >= bitmap.width * 16,
              CFDataGetLength(data) / bitmap.bytesPerRow >= bitmap.height else { return nil }
        var minimum = Float.infinity, maximum = -Float.infinity
        for y in stride(from: 0, to: bitmap.height, by: max(1, bitmap.height / 64)) {
            let row = UnsafeRawPointer(bytes.advanced(by: y * bitmap.bytesPerRow)).assumingMemoryBound(to: Float.self)
            for x in stride(from: 0, to: bitmap.width, by: max(1, bitmap.width / 64)) {
                for channel in 0..<3 {
                    let value = row[x * 4 + channel]
                    guard value.isFinite else { return nil }
                    minimum = min(minimum, value); maximum = max(maximum, value)
                }
            }
        }
        return (minimum, maximum)
    }

    static func rawBitmapIsCollapsed(_ image: PhotoImage) -> Bool {
        guard let (minimum, maximum) = rawBitmapSampleRange(image) else { return false }
        return abs(minimum) < 1e-7 && abs(maximum) < 1e-7
    }

    static func rawPreviewHasVisibleContent(_ image: PhotoImage) -> Bool {
        guard let (minimum, maximum) = rawBitmapSampleRange(image) else { return false }
        return maximum > 0.05 && maximum - minimum > 0.02
    }

    static func decodeImageSource(_ source: CGImageSource) -> PhotoImage? {
        guard CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32
        let orientation = rawOrientation
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return PhotoImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}
