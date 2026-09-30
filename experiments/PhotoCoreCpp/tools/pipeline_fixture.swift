import Foundation
import CoreImage
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import PhotoStyleShared

// 使用產品完整入口產生參考成品；不複製演算法，也不加入 App target。
enum PipelineOracleTrace {
    static var failed = false
    static var stages: [String] = []
}

@main enum PipelineFixture {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = PhotoImageRenderPrecision.makeContext()
    struct Failure: Error { let message: String }
    final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func report(_ progress: Double) { lock.lock(); defer { lock.unlock() }; if progress == 1 { value = true } }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func json(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
    static func pfm(_ image: CIImage, to url: URL) throws -> String {
        let bounds = image.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        var pixels = [Float](repeating: .nan, count: w * h * 4)
        context.render(image, toBitmap: &pixels, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: linear)
        var bytes = Data("PF\n\(w) \(h)\n-1.0\n".utf8)
        // Core Image 的 bitmap 由頂列開始；PFM 的儲存順序是底列先存。
        for y in (0..<h).reversed() { for x in 0..<w {
            let i = (y * w + x) * 4
            guard abs(pixels[i + 3] - 1) < 1e-5 else { throw Failure(message: "測試成品必須不透明") }
            for c in 0..<3 {
                guard pixels[i+c].isFinite else { throw Failure(message: "成品含非有限像素") }
                var bits = pixels[i+c].bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
        }}
        try bytes.write(to: url)
        return hash(bytes)
    }
    static func fixedInput(_ ci: CIImage, maxEdge: Double, raw: Bool) throws -> PhotoImage {
        let s = min(1, maxEdge / max(ci.extent.width, ci.extent.height))
        let bounds = CGRect(x: 0, y: 0, width: Int(ci.extent.width*s), height: Int(ci.extent.height*s))
        let resized = ci.clampedToExtent().transformed(by: .init(translationX: -ci.extent.minX, y: -ci.extent.minY))
            .transformed(by: .init(scaleX: s, y: s)).cropped(to: bounds)
        guard let bitmap = context.createCGImage(resized, from: bounds, format: .RGBAf, colorSpace: linear, deferred: false) else {
            throw Failure(message: "無法建立固定輸入")
        }
        return PhotoImage(cgImage: bitmap, requiresRAWDisplayMapping: raw)
    }
    static func main() {
        do { try run() }
        catch { fputs("完整流程參考產生失敗：\(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 4, let edge = Double(args[2]), edge >= 32 && edge <= 4096 else {
            throw Failure(message: "用法：pipeline-fixture 輸出目錄 最長邊 照片...")
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldManifest = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: oldManifest.path) { try FileManager.default.removeItem(at: oldManifest) }
        let inputs = root.appendingPathComponent("inputs"), refs = root.appendingPathComponent("reference"), recipes = root.appendingPathComponent("recipes")
        for folder in [inputs, refs, recipes] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var cases: [[String: Any]] = []
        for (index, path) in args.dropFirst(3).enumerated() {
            let url = URL(fileURLWithPath: path), data = try Data(contentsOf: url)
            // RAW 解碼差異不混入演算法：先固定一次線性輸入，再由兩端讀取相同 PFM。
            let hint = UTType(filenameExtension: url.pathExtension)?.identifier
            let filter = PhotoRAWDecoder.makeSceneLinearFilter(data: data, identifierHint: hint)
            let raw = filter != nil
            guard let ci = filter?.outputImage ?? CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw Failure(message: "無法讀取測試照片：\(url.lastPathComponent)")
            }
            var photo = try fixedInput(ci, maxEdge: edge, raw: raw)
            let sourceName = String(format: "input-%02d", index)
            let inputPath = "inputs/\(sourceName).pfm"
            let inputHash = try pfm(CIImage(cgImage: photo.cgImage!), to: root.appendingPathComponent(inputPath))
            var originalFields: [String: Any] = [:]
            if raw {
                guard let camera = CIRAWFilter(imageData: data, identifierHint: hint)?.outputImage,
                      camera.extent == ci.extent else { throw Failure(message: "缺少 RAW 原生顯影參考") }
                photo.cameraOriginal = try fixedInput(camera, maxEdge: edge, raw: false).cgImage
                let originalPath = "inputs/\(sourceName)-camera-original.pfm"
                originalFields = ["camera_original": originalPath,
                    "camera_original_sha256": try pfm(CIImage(cgImage: photo.cameraOriginal!), to: root.appendingPathComponent(originalPath))]
            }
            for style in PhotoStyle.allCases {
                for variant in ["default", "edited", "low-strength"] {
                    if variant == "low-strength" && style.filmStock == nil { continue }
                    try autoreleasepool {
                        var adjustment = StyleAdjustment.default(for: style)
                        if variant == "low-strength" { adjustment.intensity *= 0.4 }
                        if variant == "edited" {
                            adjustment.exposure = 8; adjustment.highlightExposure = -5; adjustment.shadowExposure = 7
                            adjustment.whiteBalanceWarmth = 12; adjustment.whiteBalanceTint = -4
                            adjustment.contrast = 10; adjustment.vibrance = 8; adjustment.saturation = -5
                            adjustment.hdrAmount = 15; adjustment.vignette = 8
                            adjustment.filmEffects.printExposure = 6
                            adjustment.filmEffects.developmentAmount = 20
                            adjustment.filmEffects.scanExposure = 4
                        }
                        let id = "\(sourceName)-\(style.rawValue)-\(variant)"
                        PipelineOracleTrace.failed = false
                        PipelineOracleTrace.stages = []
                        let completed = Completion()
                        let result = PhotoStyleProcessor.apply(style: style, adjustment: adjustment, to: photo,
                            shouldDetectSubjectMask: false, isPreview: false, progress: { completed.report($0) })
                        guard completed.finished && !PipelineOracleTrace.failed else { throw Failure(message: "完整流程未完成（可能回退原圖）：\(id)") }
                        guard let png = result.encodedData(format: .png, bitDepth: 16, exportColorSpace: .sRGB),
                              let exported = CIImage(data: png) else { throw Failure(message: "PNG16 匯出失敗：\(id)") }
                        try png.write(to: refs.appendingPathComponent(id + ".png"))
                        let referencePath = "reference/\(id).pfm"
                        let referenceHash = try pfm(exported, to: root.appendingPathComponent(referencePath))
                        let recipe: [String: Any] = ["schema": 1, "style": style.rawValue,
                            "adjustment": try JSONSerialization.jsonObject(with: JSONEncoder().encode(adjustment)),
                            "requiresRAWDisplayMapping": raw, "hasCameraOriginal": photo.cameraOriginal != nil, "shouldDetectSubjectMask": false,
                            "repairPatches": [], "isPreview": false,
                            "referenceStages": PipelineOracleTrace.stages + ["render-decorations", "export-png16"],
                            "export": ["format": "png", "bitDepth": 16, "colorSpace": "sRGB"],
                            "comparison": "匯出後重新解碼為 linear-sRGB PFM，頂列為座標原點"]
                        let recipePath = "recipes/\(id).json"
                        try json(recipe, to: root.appendingPathComponent(recipePath))
                        var entry: [String: Any] = ["id": id, "input": inputPath, "input_sha256": inputHash,
                            "source_sha256": hash(data), "recipe": recipePath,
                            "recipe_sha256": hash(try Data(contentsOf: root.appendingPathComponent(recipePath))),
                            "reference": referencePath, "reference_sha256": referenceHash]
                        entry.merge(originalFields) { _, new in new }
                        cases.append(entry)
                        print("完整 Swift 成品：\(id)")
                    }
                }
            }
        }
        try json(["schema": 1, "scope": "full-pipeline-final-output", "metric": "CIEDE2000",
            "threshold": 2, "aggregation": "max", "cases": cases,
            "oracle_provenance": try JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent("oracle-provenance.json"))),
            "contract": "固定解碼輸入 → PhotoStyleProcessor.apply(isPreview:false) → PNG16 sRGB 匯出 → 解碼為線性 sRGB → D65 Lab → ΔE00",
            "coverage_notes": ["全部 PhotoStyle 預設與複合調整、底片低強度分支，保留預設顆粒。",
                "不涵蓋跨平台 RAW 解碼器、AI 遮罩/景深、修復、日期、邊框及所有參數極值；此矩陣不是所有功能已移植的聲明。"]],
            to: root.appendingPathComponent("manifest.json"))
        print("已產生 \(cases.count) 組完整 Swift 參考；尚須 C++ 全流程成品比對，不能據此宣告通過。")
    }
}
