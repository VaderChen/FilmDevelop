import AppKit
import PhotoStyleShared
import ImageIO

// 僅供等待原檔解碼的畫面使用，不進入編輯或匯出管線。
func loadingPreviewDataURL(from data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PhotoImage.previewMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { return nil }
    return imageDataURL(PhotoImage(cgImage: thumbnail))
}

func imageDataURL(_ image: PhotoImage?, maxPixel: CGFloat? = PhotoImage.previewMaxPixel) -> String? {
    guard let image else { return nil }
    let displayImage = maxPixel.map { image.resizedForWebPreview(maxPixel: $0) } ?? image
    guard let data = displayImage.jpegData(compressionQuality: 0.88) else {
        return nil
    }
    return "data:image/jpeg;base64,\(data.base64EncodedString())"
}

func imageSizePayload(_ image: PhotoImage?) -> [String: Any]? {
    guard let image else { return nil }
    let width = image.cgImage.map { CGFloat($0.width) } ?? image.size.width * image.scale
    let height = image.cgImage.map { CGFloat($0.height) } ?? image.size.height * image.scale
    return [
        "width": width,
        "height": height
    ]
}

func croppedImageSizePayload(
    _ image: PhotoImage?,
    adjustment: StyleAdjustment
) -> [String: Any]? {
    guard let image else { return nil }
    let pixelSize = CGSize(
        width: image.size.width * image.scale,
        height: image.size.height * image.scale
    )
    let cropRect = adjustment.cropRect(in: CGRect(origin: .zero, size: pixelSize))
    return [
        "width": cropRect.width,
        "height": cropRect.height
    ]
}

func croppedImage(_ image: PhotoImage, adjustment: StyleAdjustment) -> PhotoImage {
    let image = image.rotatedForCrop(degrees: adjustment.cropRotation)
    let cropRect = adjustment.cropRect(in: CGRect(origin: .zero, size: image.size))
    guard cropRect != CGRect(origin: .zero, size: image.size) else {
        return image
    }

    return image.cropped(to: cropRect)
}

func croppedImageForAnalysis(
    _ image: PhotoImage,
    adjustment: StyleAdjustment,
    maxPixel: CGFloat
) -> PhotoImage {
    croppedImage(image, adjustment: adjustment).resizedForWebPreview(maxPixel: maxPixel)
}

func palette(for style: PhotoStyle) -> [String] {
    if let camera = style.cameraProfile { return camera.palette }
    if let stock = style.filmStock { return stock.palette }
    switch style {
    case .original:
        return ["#949a97", "#dbddd6", "#eeece4"]
    case .autoDetection:
        return ["#3f83f8", "#f8faf7", "#f0a54b"]
    case .japaneseColor1:
        return ["#6b818b", "#d8e0e2", "#ecdebc"]
    case .japaneseColor2:
        return ["#f6b6c8", "#fff7fb", "#98dce5"]
    case .japaneseBWStrong:
        return ["#1f1f1f", "#747474", "#f7f7f7"]
    case .japaneseBWStandard:
        return ["#20201f", "#77756d", "#dbd7c9"]
    case .japaneseBWSoft:
        return ["#9a9a9a", "#d8d8d8", "#ffffff"]
    case .fujiProvia:
        return ["#5a9367", "#4f7cac", "#93d2bd"]
    case .fujiClassicChrome:
        return ["#536d8a", "#a0a4a8", "#d39a66"]
    case .fujiClassicNeg:
        return ["#33575a", "#aaa990", "#c1553d"]
    default:
        return ["#403c35", "#bba87c", "#efe4cd"]
    }
}
