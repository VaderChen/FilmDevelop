import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Configures Apple's demosaiced RGB output for the scene-referred pipeline.
/// This is not access to Bayer/CFA samples; camera white balance, demosaicing,
/// and the decoder's camera-specific noise reduction and sharpening remain active.
public enum PhotoRAWDecoder {
    public static func makeSceneLinearFilter(data: Data, identifierHint: String?, lensCorrectionEnabled: Bool = true) -> CIRAWFilter? {
        // Inspect the bytes rather than trusting the filename/hint.
        // X-Trans RAF can omit CFA/Maker/Photometric tags in CIRAWFilter's
        // properties, and LinearRaw DNG legitimately has no CFA at all.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let sourceType = UTType(type as String),
              let filter = CIRAWFilter(imageData: data, identifierHint: identifierHint),
              // Malformed inputs can violate the SDK's nonnull annotation. KVC
              // preserves Objective-C nil instead of trapping in Swift bridging.
              let properties = filter.value(forKey: "properties") as? NSDictionary,
              ((properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0) > 8,
              isRAWContent(sourceType: sourceType, properties: properties) else { return nil }

        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = lensCorrectionEnabled
        }
        filter.scaleFactor = 1
        filter.isDraftModeEnabled = false
        filter.exposure = 0
        // 保留解碼器依 RAW 設定的基準曝光補償，讓底片從校正後的曝光開始。
        // 它是線性曝光增益，與下方停用的顯影曲線及局部色調映射不同。
        // 強制歸零會讓需要正補償的照片在所有底片中一致偏暗。
        // shadowBias subtracts from shadows; it is not a measured sensor black
        // level or an EV value. Leaving the camera default here can erase the
        // low-light signal before the app's exposure adjustment sees it.
        filter.shadowBias = 0
        filter.boostAmount = 0
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        filter.isGamutMappingEnabled = false
        filter.extendedDynamicRangeAmount = 2
        return filter
    }

    private static func isRAWContent(sourceType: UTType, properties: NSDictionary) -> Bool {
        if sourceType.conforms(to: .rawImage) { return true }
        // ImageIO recognizes some NEF byte snapshots only as TIFF; the URL's
        // extension is unavailable here. Require actual raw photometric data
        // from the decoder, not a MakerNote or camera name retained in an export.
        guard sourceType.conforms(to: .tiff),
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary,
              let interpretation = tiff[kCGImagePropertyTIFFPhotometricInterpretation] as? NSNumber else { return false }
        return interpretation.intValue == 32_803 || interpretation.intValue == 34_892
    }

}
