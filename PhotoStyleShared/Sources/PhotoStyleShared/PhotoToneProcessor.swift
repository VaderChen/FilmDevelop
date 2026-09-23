import CoreImage

public enum PhotoTemperatureProfile: Sendable {
    case app
    case plan
}

public enum PhotoToneProcessor {
    /// Fit the existing temperature/tint controls to a display-referred neutral sample.
    public static func neutralBalance(sRGB: [Double], warmth: Double, tint: Double,
                                      strength: Double) -> (warmth: Double, tint: Double)? {
        guard sRGB.count == 3, sRGB.allSatisfy({ $0.isFinite && $0 > 0.02 && $0 < 0.99 }),
              strength > 0, strength <= 1 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let sample = CIImage(color: CIColor(red: sRGB[0], green: sRGB[1], blue: sRGB[2]))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let base = sample.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500 - warmth * strength * 18, y: -tint * strength * 0.6),
            "inputTargetNeutral": CIVector(x: 6500, y: 0)
        ])
        func loss(_ w: Double, _ t: Double) -> Double {
            let image = applyTemperatureAndTint(to: base, warmth: w * strength, tint: t * strength, profile: .app)
            var pixel = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: sample.extent, format: .RGBAf, colorSpace: space)
            let r = log(max(1e-8, Double(pixel[0])) / max(1e-8, Double(pixel[1])))
            let b = log(max(1e-8, Double(pixel[2])) / max(1e-8, Double(pixel[1])))
            return r*r + b*b
        }
        var w = warmth, t = tint, best = loss(warmth, tint)
        for step in [40.0, 10, 2.5, 0.5, 0.1] {
            for _ in 0..<5 {
                var nextW = w, nextT = t
                for dw in [-step, 0, step] { for dt in [-step, 0, step] {
                    let cw = min(100, max(-100, w + dw)), ct = min(100, max(-100, t + dt))
                    let value = loss(cw, ct)
                    if value < best { best = value; nextW = cw; nextT = ct }
                } }
                if nextW == w && nextT == t { break }
                w = nextW; t = nextT
            }
        }
        return (w, t)
    }

    public static func applyExposure(to image: CIImage, ev: Double) -> CIImage {
        PhotoAdaptiveExposureProcessor.apply(to: image, ev: ev)
    }

    public static func applyContrast(to image: CIImage, amount: Double) -> CIImage {
        PhotoLocalToneProcessor.apply(to: image, contrast: amount)
    }

    public static func applyTemperatureAndTint(
        to image: CIImage,
        warmth: Double,
        tint: Double,
        profile: PhotoTemperatureProfile
    ) -> CIImage {
        guard abs(warmth) > 0.001 || abs(tint) > 0.001 else { return image }

        let target: CIVector
        switch profile {
        case .app:
            let warmth = min(max(warmth, -100), 100)
            let tint = min(max(tint, -100), 100)
            target = CIVector(
                x: min(max(6500 - warmth * 18, 4300), 8500),
                y: min(max(-tint * 0.6, -60), 60)
            )
        case .plan:
            target = CIVector(x: 6500 - warmth * 2500, y: -tint * 80)
        }
        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": target
        ])
    }

    public static func applyHighlightShadow(
        to image: CIImage,
        highlights: Double,
        shadows: Double
    ) -> CIImage {
        PhotoLocalToneProcessor.apply(
            to: image,
            highlights: highlights,
            shadows: shadows
        )
    }
}
