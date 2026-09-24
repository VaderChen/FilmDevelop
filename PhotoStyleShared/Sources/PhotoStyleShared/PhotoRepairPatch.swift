import Foundation
import CoreImage

/// 修復結果獨立於底片配方，以原始照片的正規化座標保存，預覽及匯出共用。
public struct PhotoRepairPatch: Codable, Equatable, Sendable {
    public let id: UUID
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let imageData: Data
    public let maskData: Data
    public let linearGain: Double

    public init(x: Double, y: Double, width: Double, height: Double,
                imageData: Data, maskData: Data, linearGain: Double = 1) {
        id = UUID(); self.x = x; self.y = y; self.width = width; self.height = height
        self.imageData = imageData; self.maskData = maskData; self.linearGain = linearGain
    }

    public static func applying(_ patches: [Self], to source: CIImage) -> CIImage {
        let extent = source.extent
        return patches.reduce(source) { image, patch in
            guard [patch.x, patch.y, patch.width, patch.height, patch.linearGain].allSatisfy(\.isFinite),
                  patch.width > 0, patch.height > 0, patch.linearGain > 0,
                  let replacement = CIImage(data: patch.imageData),
                  let mask = CIImage(data: patch.maskData, options: [.colorSpace: NSNull()]) else { return image }
            let rect = CGRect(x: extent.minX + patch.x * extent.width, y: extent.minY + patch.y * extent.height,
                              width: patch.width * extent.width, height: patch.height * extent.height)
            func fit(_ value: CIImage) -> CIImage {
                let sx = rect.width / value.extent.width, sy = rect.height / value.extent.height
                return value.transformed(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                    tx: rect.minX - value.extent.minX * sx, ty: rect.minY - value.extent.minY * sy)).cropped(to: rect)
            }
            let filled = fit(replacement).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(patch.linearGain)])
            return filled.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: fit(mask)
            ]).cropped(to: extent)
        }
    }
}
