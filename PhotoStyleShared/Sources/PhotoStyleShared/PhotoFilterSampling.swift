import CoreImage

/// 係數圖使用完整像素格；縮放前延伸邊緣，避免奇數尺寸或狹長照片混入透明像素。
struct PhotoFilterSampling {
    let extent: CGRect
    let sampledExtent: CGRect
    let downsample: CGAffineTransform
    let upsample: CGAffineTransform

    init?(extent: CGRect, scale: CGFloat) {
        guard !extent.isEmpty, !extent.isInfinite,
              [extent.minX, extent.minY, extent.width, extent.height, scale].allSatisfy(\.isFinite),
              scale > 0, scale <= 1 else { return nil }
        self.extent = extent
        let width = max(1, (extent.width * scale).rounded())
        let height = max(1, (extent.height * scale).rounded())
        sampledExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let sx = width / extent.width, sy = height / extent.height
        downsample = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                      tx: -extent.minX * sx, ty: -extent.minY * sy)
        upsample = downsample.inverted()
    }

    func sample(_ image: CIImage) -> CIImage {
        image.cropped(to: extent).clampedToExtent().transformed(by: downsample).cropped(to: sampledExtent)
    }

    func reconstruct(_ image: CIImage) -> CIImage {
        image.cropped(to: sampledExtent).clampedToExtent().transformed(by: upsample).cropped(to: extent)
    }
}
