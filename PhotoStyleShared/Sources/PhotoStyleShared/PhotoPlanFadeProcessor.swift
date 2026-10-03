import CoreImage

/// 分區淡化使用單一單調曲線，避免黑位抬升後在遮罩交界反轉明暗。
enum PhotoPlanFadeProcessor {
    private static let sampleCount = 1025
    private static let minimumSlope = 0.1
    private static let luminanceAttenuation = 0.209186
    private static let kernel = CIKernel(source: """
    kernel vec4 planFade(sampler source, sampler curve, float lastSample) {
        vec4 s = sample(source, samplerCoord(source));
        if (s.a <= 0.0) return s;
        float y = dot(s.rgb / s.a, vec3(0.2126, 0.7152, 0.0722));
        float position = clamp(y, 0.0, 1.0) * lastSample;
        float lift = sample(curve, samplerTransform(curve, vec2(position + 0.5, 0.5))).r;
        return vec4(s.rgb * (vec3(1.0) - lift * vec3(0.25, 0.20, 0.18))
                    + vec3(lift * s.a), s.a);
    }
    """)

    static func apply(to image: CIImage, amounts: SIMD3<Double>, masks: PhotoToneMasks) -> CIImage {
        guard amounts.max() > 0, let kernel, !image.extent.isEmpty else { return image }
        let values = lifts(amounts: amounts, profile: masks.profile, middleGray: masks.middleGray)
        var pixels = [Float]()
        pixels.reserveCapacity(values.count * 4)
        for value in values { pixels.append(contentsOf: [value, value, value, 1]) }
        let curve = pixels.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: values.count * 16,
                    size: CGSize(width: values.count, height: 1), format: .RGBAf, colorSpace: nil)
        }.samplingLinear()
        return kernel.apply(extent: image.extent, roiCallback: { index, area in
            index == 0 ? area : curve.extent
        }, arguments: [image, curve, Float(values.count - 1)]) ?? image
    }

    static func lifts(amounts: SIMD3<Double>, profile: PhotoToneMaskProfile, middleGray: Double) -> [Float] {
        let p = PhotoToneMasks.parameters(for: profile)
        let gray = min(max(middleGray, 0.01), 0.5)
        func smooth(_ lo: Double, _ hi: Double, _ value: Double) -> Double {
            let t = min(max((value - lo) / (hi - lo), 0), 1)
            return t * t * (3 - 2 * t)
        }
        // PAVA 最小平方單調投影；先扣除最低斜率，避免把細節壓成平臺。
        // 僅 1025 個樣本，O(樣本數)；不讀回照片，也不建立全尺寸遮罩。
        var sums = [Double](), counts = [Int]()
        sums.reserveCapacity(sampleCount); counts.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let y = Double(i) / Double(sampleCount - 1)
            let stops = log2(max(y, 0.000001) / gray)
            let sigma = Double(stops < 0 ? p.negativeSigma : p.positiveSigma)
            let weights = SIMD3(
                1 - smooth(Double(p.shadowStart), Double(p.shadowEnd), stops),
                exp2(-0.5 * pow(stops / sigma, 2)),
                smooth(Double(p.highlightStart), Double(p.highlightEnd), stops))
            let lift = 0.18 * (weights * amounts).sum() / weights.sum()
            sums.append(y * (1 - luminanceAttenuation * lift) + lift - minimumSlope * y)
            counts.append(1)
            while sums.count > 1 {
                let last = sums.count - 1
                if sums[last - 1] / Double(counts[last - 1]) <= sums[last] / Double(counts[last]) { break }
                let sum = sums.removeLast(), count = counts.removeLast()
                sums[last - 1] += sum
                counts[last - 1] += count
            }
        }
        var values = [Float]()
        values.reserveCapacity(sampleCount)
        for (sum, count) in zip(sums, counts) {
            for _ in 0..<count {
                let y = Double(values.count) / Double(sampleCount - 1)
                let mapped = sum / Double(count) + minimumSlope * y
                values.append(Float(max(0, (mapped - y) / (1 - luminanceAttenuation * y))))
            }
        }
        return values
    }
}
