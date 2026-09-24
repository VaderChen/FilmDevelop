import CoreImage

/// 導向濾波共用的離散視窗平均：半徑 r 對應 (2r + 1)² 個樣本。
enum PhotoBoxMeanFilter {
    static func apply(_ image: CIImage, radius: Double) -> CIImage {
        guard radius.isFinite, radius > 0 else { return image }
        // CIBoxBlur 的 inputRadius 實際表示視窗寬度。
        // 直接傳入論文半徑 2 會退化成單點取樣，讓磨皮／細節分離失效。
        let width = 2 * radius.rounded() + 1
        return image.clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: width])
            .cropped(to: image.extent)
    }
}
