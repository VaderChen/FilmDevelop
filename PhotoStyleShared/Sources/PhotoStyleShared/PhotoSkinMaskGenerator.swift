import CoreImage

public enum PhotoSkinMaskProfile: Sendable {
    case app
    case plan
}

public enum PhotoSkinMaskGenerator {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 skinMask(__sample s) {
            vec3 rgb = s.rgb / max(s.a, 0.00001);
            float r = rgb.r;
            float g = rgb.g;
            float b = rgb.b;
            float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float maxc = max(r, max(g, b));
            float minc = min(r, min(g, b));
            float chroma = maxc - minc;
            float saturation = chroma / max(maxc, 0.001);
            float cb = (b - l) * 0.565;
            float cr = (r - l) * 0.713;
            float hue = 0.0;
            if (chroma > 0.0001) {
                if (maxc == r) {
                    hue = (g - b) / chroma;
                    if (hue < 0.0) { hue += 6.0; }
                } else if (maxc == g) {
                    hue = ((b - r) / chroma) + 2.0;
                } else {
                    hue = ((r - g) / chroma) + 4.0;
                }
                hue *= 60.0;
            }

            float lumaMask = smoothstep(0.06, 0.18, l) * (1.0 - smoothstep(0.96, 1.0, l));
            float saturationMask = smoothstep(0.015, 0.080, saturation) * (1.0 - smoothstep(0.76, 0.96, saturation));

            float rgbNormal = smoothstep(0.24, 0.38, r)
                * smoothstep(0.10, 0.18, g)
                * smoothstep(0.04, 0.10, b)
                * smoothstep(0.035, 0.10, chroma)
                * smoothstep(-0.03, 0.07, r - g)
                * smoothstep(-0.04, 0.08, r - b)
                * (1.0 - smoothstep(0.32, 0.58, abs(r - g)))
                * (1.0 - smoothstep(0.02, 0.20, g - r));

            float rgbBright = smoothstep(0.72, 0.86, r)
                * smoothstep(0.66, 0.82, g)
                * smoothstep(0.54, 0.72, b)
                * (1.0 - smoothstep(0.06, 0.18, abs(r - g)))
                * smoothstep(-0.02, 0.07, r - b)
                * smoothstep(-0.02, 0.07, g - b);

            float ycbcrFamily = smoothstep(-0.245, -0.185, cb)
                * (1.0 - smoothstep(0.010, 0.070, cb))
                * smoothstep(0.015, 0.070, cr)
                * (1.0 - smoothstep(0.205, 0.280, cr));

            float hueLow = 1.0 - smoothstep(48.0, 76.0, hue);
            float hueHigh = smoothstep(332.0, 348.0, hue);
            float hsvFamily = max(hueLow, hueHigh)
                * smoothstep(0.05, 0.18, saturation)
                * (1.0 - smoothstep(0.72, 0.92, saturation))
                * smoothstep(0.12, 0.24, maxc);

            float warmFamily = smoothstep(-0.16, 0.035, r - b)
                * (1.0 - smoothstep(0.30, 0.58, abs(r - g)))
                * (1.0 - smoothstep(0.04, 0.24, g - r));

            float skinFamily = max(max(rgbNormal, rgbBright), max(ycbcrFamily, max(hsvFamily, warmFamily)));
            float m = clamp(lumaMask * saturationMask * skinFamily, 0.0, 1.0);
            return vec4(m, m, m, 1.0);
        }
        """)

    public static func make(from image: CIImage, personMask: CIImage?, profile: PhotoSkinMaskProfile) -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return CIImage.empty() }
        let rawMask: CIImage
        if let kernel,
           let output = kernel.apply(extent: extent, arguments: [image]) {
            rawMask = output
        } else {
            rawMask = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
        }

        let masked = personMask.map { mask in
            let softSubject = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.95, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.95, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.05, y: 0.05, z: 0.05, w: 0)
            ])
            return rawMask.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: softSubject
            ])
        } ?? rawMask

        let radiusScale = radiusScale(for: extent, profile: profile)
        return PhotoGuidedMaskRefiner.refine(
            masked, guidedBy: image, radius: max(2, 4 * radiusScale), epsilon: 0.0004
        )
    }

    private static func radiusScale(for extent: CGRect, profile: PhotoSkinMaskProfile) -> Double {
        switch profile {
        case .app:
            return max(min(extent.width, extent.height) / 1600, 0.5)
        case .plan:
            return min(max(max(extent.width, extent.height) / 1024, 0.5), 3)
        }
    }
}
