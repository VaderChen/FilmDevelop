import Foundation
import CoreGraphics

public enum PhotoCropCalculator {
    /// Clockwise in the UI; Core Image uses an upward Y axis. Zoom just enough
    /// to cover the original rectangle, so every crop position stays opaque.
    public static func rotationTransform(in extent: CGRect, clockwiseDegrees: Double) -> CGAffineTransform {
        guard isUsableExtent(extent), clockwiseDegrees.isFinite else { return .identity }
        let radians = min(max(clockwiseDegrees, -45), 45) * .pi / 180
        guard abs(radians) > 0.0000001 else { return .identity }
        let c = abs(cos(radians)), s = abs(sin(radians))
        let scale = max(c + s * extent.height / extent.width,
                        c + s * extent.width / extent.height)
        return CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: -radians).scaledBy(x: scale, y: scale)
            .translatedBy(x: -extent.midX, y: -extent.midY)
    }

    public static func centeredCropRect(
        in extent: CGRect,
        targetAspectRatio: CGFloat?
    ) -> CGRect {
        guard isUsableExtent(extent),
              let targetAspectRatio,
              targetAspectRatio.isFinite,
              targetAspectRatio > 0 else {
            return extent
        }

        let sourceAspectRatio = extent.width / extent.height
        guard abs(sourceAspectRatio - targetAspectRatio) > 0.000_001 else {
            return extent
        }

        if sourceAspectRatio > targetAspectRatio {
            let width = extent.height * targetAspectRatio
            guard width.isFinite, width > 0 else { return extent }
            return CGRect(
                x: extent.midX - width / 2,
                y: extent.minY,
                width: width,
                height: extent.height
            )
        }

        let height = extent.width / targetAspectRatio
        guard height.isFinite, height > 0 else { return extent }
        return CGRect(
            x: extent.minX,
            y: extent.midY - height / 2,
            width: extent.width,
            height: height
        )
    }

    public static func positionedCropRect(
        in extent: CGRect,
        targetAspectRatio: CGFloat?,
        widthScale: CGFloat,
        heightScale: CGFloat,
        horizontalPosition: CGFloat,
        verticalPosition: CGFloat
    ) -> CGRect {
        guard isUsableExtent(extent) else { return extent }
        let baseRect = centeredCropRect(in: extent, targetAspectRatio: targetAspectRatio)
        // NaN survives min/max. Treat an undefined control value as its neutral
        // setting so one malformed value cannot produce an unrenderable CGRect.
        let width = baseRect.width * min(max(widthScale.isNaN ? 1 : widthScale, 0.01), 1)
        let height = baseRect.height * min(max(heightScale.isNaN ? 1 : heightScale, 0.01), 1)
        let horizontalUnit = (min(max(horizontalPosition.isNaN ? 0 : horizontalPosition, -1), 1) + 1) / 2
        let verticalUnit = (min(max(verticalPosition.isNaN ? 0 : verticalPosition, -1), 1) + 1) / 2

        return CGRect(
            x: extent.minX + (extent.width - width) * horizontalUnit,
            y: extent.minY + (extent.height - height) * verticalUnit,
            width: width,
            height: height
        )
    }

    private static func isUsableExtent(_ extent: CGRect) -> Bool {
        !extent.isInfinite && !extent.isEmpty
            && extent.minX.isFinite && extent.minY.isFinite
            && extent.maxX.isFinite && extent.maxY.isFinite
    }
}
