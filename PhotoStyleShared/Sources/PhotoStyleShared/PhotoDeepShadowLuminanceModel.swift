import CoreImage
import CoreML
import CryptoKit
import Foundation
import os

/// Fixed-size luminance inference and joint upsampling coefficients. No source
/// chroma enters the model. Only two small maps are retained, never full RAWs.
final class PhotoDeepShadowLuminanceModel: @unchecked Sendable {
    static let shared = PhotoDeepShadowLuminanceModel()
    static let width = 384, height = 256
    private let lock = NSLock()
    private var model: MLModel?
    private var cache: [(key: Data, image: CIImage)] = []
    private let logger = Logger(subsystem: "PhotoStyleShared", category: "DeepShadow")
    private var completedInferenceCount = 0
    var inferenceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return completedInferenceCount
    }

    func coefficients(for encodedY: [Float]) -> CIImage? {
        guard encodedY.count == Self.width * Self.height else { return nil }
        let key = encodedY.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
        lock.lock(); defer { lock.unlock() }
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: index); cache.append(hit)
            return hit.image
        }
        do {
            let model = try loadModel()
            let input = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.height), NSNumber(value: Self.width)], dataType: .float32)
            let inputPointer = input.dataPointer.assumingMemoryBound(to: Float.self)
            for i in encodedY.indices { inputPointer[i] = encodedY[i] }
            var enhanced = [Float](repeating: 0, count: encodedY.count)
            // Two passes provide enough headroom for severely underexposed RAWs.
            // The user controls the final strength through luminance blending.
            for pass in 0..<2 {
                let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["luminance": input]))
                guard let output = prediction.featureValue(for: "enhancedLuminance")?.multiArrayValue,
                      output.count == enhanced.count, output.shape.map(\.intValue) == [1, 1, Self.height, Self.width],
                      (output.dataType == .float32 || output.dataType == .float16) else { throw ModelError.invalidOutput }
                let sy = output.strides[2].intValue, sx = output.strides[3].intValue
                let values = output.dataPointer.assumingMemoryBound(to: Float.self)
                let halfValues = output.dataPointer.assumingMemoryBound(to: Float16.self)
                let isHalf = output.dataType == .float16
                for row in 0..<Self.height { for col in 0..<Self.width {
                    let i = row * Self.width + col
                    let index = row * sy + col * sx
                    let value = isHalf ? Float(halfValues[index]) : values[index]
                    guard value.isFinite else { throw ModelError.invalidOutput }
                    enhanced[i] = min(1, max(0, value))
                    if pass == 0 { inputPointer[i] = Self.encode(enhanced[i]) }
                }}
            }
            completedInferenceCount += 1
            let image = Self.makeCoefficients(source: encodedY, enhanced: enhanced)
            cache.append((key, image))
            if cache.count > 2 { cache.removeFirst() }
            return image
        } catch {
            logger.error("Luminance enhancement unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private enum ModelError: Error { case missingResource, invalidOutput }
    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.module.url(forResource: "LYTLuminance", withExtension: "mlpackage", subdirectory: "Resources") else { throw ModelError.missingResource }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        // Keep Core ML's compiled package across launches. A changed model spec
        // or weight file creates a new key; an incompatible OS cache is rebuilt.
        var fingerprint = SHA256()
        for path in ["Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
            fingerprint.update(data: try Data(contentsOf: url.appendingPathComponent(path)))
        }
        let key = fingerprint.finalize().map { String(format: "%02x", $0) }.joined()
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PhotoStyleShared/Luminance", isDirectory: true)
        let cached = cacheRoot?.appendingPathComponent("lyt-\(key).mlmodelc", isDirectory: true)
        if let cached, let loaded = try? MLModel(contentsOf: cached, configuration: configuration) {
            model = loaded
            return loaded
        }
        let compiled = try MLModel.compileModel(at: url)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let result = try MLModel(contentsOf: compiled, configuration: configuration)
        // Cache publication is best-effort; another process may publish first.
        if let cacheRoot, let cached {
            try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let staging = cacheRoot.appendingPathComponent(UUID().uuidString + ".mlmodelc")
            if (try? FileManager.default.copyItem(at: compiled, to: staging)) != nil {
                if FileManager.default.fileExists(atPath: cached.path) {
                    try? FileManager.default.removeItem(at: cached)
                }
                try? FileManager.default.moveItem(at: staging, to: cached)
                try? FileManager.default.removeItem(at: staging)
            }
        }
        model = result
        return result
    }

    private static func encode(_ y: Float) -> Float {
        y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
    }
    private static func decode(_ y: Float) -> Float {
        y <= 0.04045 ? y / 12.92 : pow((y + 0.055) / 1.055, 2.4)
    }

    /// Fast joint guided upsampling in log luminance: fit the low-resolution
    /// enhanced signal to the original guide, then evaluate at full resolution.
    /// A slope floor preserves local contrast instead of flattening texture;
    /// a ceiling of one avoids amplifying noise in the log-luminance residual.
    private static func makeCoefficients(source: [Float], enhanced: [Float]) -> CIImage {
        let guide = source.map { log2(max(decode($0), 1e-8)) }
        let target = enhanced.map { log2(max($0, 1e-8)) }
        let meanG = boxMean(guide), meanT = boxMean(target)
        let meanGG = boxMean(guide.map { $0 * $0 })
        let meanGT = boxMean(zip(guide, target).map(*))
        var a = [Float](repeating: 0, count: source.count), b = a
        for i in source.indices {
            let variance = max(0, meanGG[i] - meanG[i] * meanG[i])
            a[i] = min(1, max(0.5, (meanGT[i] - meanG[i] * meanT[i]) / (variance + 0.04)))
            b[i] = meanT[i] - a[i] * meanG[i]
        }
        a = boxMean(a); b = boxMean(b)
        var pixels = [SIMD4<Float>](repeating: .zero, count: source.count)
        for i in pixels.indices { pixels[i] = SIMD4(a[i], b[i], 0, 1) }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }

    private static func boxMean(_ input: [Float]) -> [Float] {
        let stride = width + 1, radius = 4
        var integral = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var sum = 0.0
            for x in 0..<width {
                sum += Double(input[y * width + x])
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + sum
            }
        }
        var result = [Float](repeating: 0, count: input.count)
        for y in 0..<height { for x in 0..<width {
            let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1]
                - integral[y1 * stride + x0] + integral[y0 * stride + x0]
            result[y * width + x] = Float(sum / Double((x1 - x0) * (y1 - y0)))
        }}
        return result
    }
}
