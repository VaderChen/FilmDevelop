import CoreImage
import Foundation
import Metal

// 由 emulsion-smoke.py 編譯。直接讀取產品使用的 Metal 核心，參照路徑
// 保留舊 Swift 的逐樣本演算法；不經 JPEG、色彩編碼或桌面成品快取。
@main enum EmulsionSmoke {
    struct Case {
        let name: String, width: Int, height: Int
        let size: Double, clumping: Double, chroma: Double, seed: UInt32, spread: Double, pitch: Double
        var origin: CGPoint = .zero
        var tileSize: Int = 0
        var performance = false
        var parameters: [Any] { [size, clumping, chroma, Double(seed & 65535), Double(seed >> 16), spread, pitch] }
    }
    static func failure(_ message: String) -> NSError { NSError(domain: message, code: 1) }
    static func kernel(_ path: String, _ name: String) throws -> CIKernel {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let parts = text.components(separatedBy: "\"\"\"")
        guard parts.count == 3 else { throw failure("乳劑 Metal 原始碼格式改變，請同步更新驗證程式") }
        let kernels = try CIKernel.kernels(withMetalString: parts[1])
        guard let result = kernels.first(where: { $0.name == name }) else { throw failure("找不到核心：\(name)") }
        return result
    }
    static func main() {
        do { try run() }
        catch { fputs("乳劑驗證失敗：\(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let device = MTLCreateSystemDefaultDevice() else { throw failure("需要原始碼、參照原始碼、報告路徑及 Metal GPU") }
        let reference = try kernel(args[2], "emulsionCapture")
        let shared = try kernel(args[1], "emulsionCaptureShared")
        // 每條路徑有獨立 context；每次渲染仍清除快取，避免回用前一次
        // 相同參數的影像，導致錯把舊結果當成另一個核心的新輸出。
        func context() -> CIContext { CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false]) }
        let referenceContext = context(), sharedContext = context()
        var cases = [Case]()
        let sizes: [Double] = [0.15, 0.5, 1, 2.4, 8, 18]
        let spreads: [Double] = [0, 0.3, 0.65, 1], pitches: [Double] = [1, 1.5, 3, 1.125]
        for i in 0..<48 {
            cases.append(Case(name: "參數組合-\(i)", width: 257, height: 173,
                size: sizes[i%6], clumping: [0, 0.4, 1][i%3], chroma: [0, 0.7, 1][i/3%3],
                seed: UInt32(i*1939)<<16 | UInt32(i*571%65536), spread: spreads[i/6%4], pitch: pitches[i/6%4],
                origin: CGPoint(x: i%2 == 0 ? 0 : -17.25, y: i%3 == 0 ? 0 : 11.5), tileSize: i>=24 ? 64 : 0))
        }
        var state: UInt32 = 0x17ca8501
        func random() -> Double {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return Double(state)/Double(UInt32.max)
        }
        for i in 0..<24 {
            let size = 0.15+random()*17.85, clumping = random(), chroma = random()
            let seed = state, spread = random(), pitch = 1+random()*2
            let origin = CGPoint(x: random()*2048-1024, y: random()*2048-1024)
            cases.append(Case(name: "固定種子隨機組合-\(i)", width: 769, height: 513,
                size: size, clumping: clumping, chroma: chroma, seed: seed, spread: spread, pitch: pitch,
                origin: origin, tileSize: i%2 == 0 ? 256 : 0))
        }
        cases += [
            Case(name: "標準顆粒大圖", width: 2048, height: 1365, size: 1, clumping: 0, chroma: 1, seed: 0, spread: 0, pitch: 1, performance: true),
            Case(name: "粗顆粒分布大圖", width: 2048, height: 1365, size: 2.4, clumping: 0.8, chroma: 0.7, seed: 0xffff04d2, spread: 0.65, pitch: 1.5, origin: CGPoint(x: -17.25, y: 11.5), performance: true),
            Case(name: "完整物理座標與分塊", width: 3000, height: 1001, size: 0.5, clumping: 1, chroma: 1, seed: 0xffffffff, spread: 1, pitch: 1, tileSize: 512),
            Case(name: "粗顆粒小預覽分塊", width: 1024, height: 683, size: 18, clumping: 1, chroma: 0, seed: 0x80000000, spread: 1, pitch: 3000.0/1024, tileSize: 256)
        ]
        var rows = [[String: Any]]()
        for item in cases {
            try autoreleasepool {
                let w = item.width, h = item.height
                var values = [Float](repeating: 1, count: w*h*4)
                for i in 0..<w*h {
                    let x = i%w, y = i/w
                    let alpha: Float = x%31 == 0 ? 0 : (x%19 == 0 ? 0.5 : 1)
                    values[i*4] = Float((x*71+y*31)%1021)/1020*alpha
                    values[i*4+1] = Float((x*3+y*79)%511)/510*alpha*4
                    values[i*4+2] = Float((x*139+y*53)%2047)/2046*alpha*16
                    values[i*4+3] = alpha
                }
                let source = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: w*16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
                    .transformed(by: .init(translationX: item.origin.x, y: item.origin.y))
                let bounds = source.extent.integral, rw = Int(bounds.width), rh = Int(bounds.height)
                func render(_ kernel: CIKernel, _ context: CIContext, tiled: Bool = false) throws -> ([Float], Double) {
                    context.clearCaches()
                    let start = DispatchTime.now().uptimeNanoseconds
                    let radius = 12*item.size/item.pitch
                    guard let graph = kernel.apply(extent: source.extent, roiCallback: { _, rect in rect.insetBy(dx: -radius, dy: -radius) }, arguments: [source.clampedToExtent()]+item.parameters) else { throw failure("核心建立失敗") }
                    var pixels = [Float](repeating: .nan, count: rw*rh*4)
                    try pixels.withUnsafeMutableBytes { bytes in
                        let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: rw, height: rh, bytesPerRow: rw*16, format: .RGBAf)
                        destination.colorSpace = nil
                        let step = tiled && item.tileSize>0 ? item.tileSize : max(rw,rh)
                        for y in stride(from: 0, to: rh, by: step) { for x in stride(from: 0, to: rw, by: step) {
                            let size = CGSize(width: min(step,rw-x), height: min(step,rh-y))
                            let origin = CGPoint(x: bounds.minX+CGFloat(x), y: bounds.minY+CGFloat(y))
                            let rect = CGRect(origin: origin, size: size)
                            let task = try context.startTask(toRender: graph, from: rect, to: destination, at: CGPoint(x: x,y: y))
                            _ = try task.waitUntilCompleted()
                        } }
                    }
                    guard pixels.allSatisfy(\.isFinite) else { throw failure("\(item.name)：未完成渲染或包含非有限值") }
                    return (pixels, Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
                }
                // Core Image 的紋理座標量化會受 tile 的輸入範圍影響；兩條
                // 路徑使用同一分塊配置，才能單獨驗證晶體共用的差異。
                let original = try render(reference, referenceContext, tiled: true).0
                let result = try render(shared, sharedContext, tiled: true).0
                guard original.contains(where: { $0>2 }) else { throw failure("\(item.name)：HDR 測試資料未正確渲染") }
                var maxError = 0.0, alphaError = 0.0, squares = 0.0, changed = 0
                for i in original.indices {
                    let delta = abs(Double(result[i])-Double(original[i]))
                    maxError = max(maxError,delta); squares += delta*delta
                    if i%4 == 3 { alphaError=max(alphaError,delta) }
                    if result[i].bitPattern != original[i].bitPattern { changed += 1 }
                }
                let rmse = sqrt(squares/Double(original.count))
                // HDR 測資最高 16；門檻只容許浮點尾數差異，晶體命中改變會失敗。
                let passed = maxError<=0.00002 && alphaError<=0.000001 && rmse<=0.000001
                var row: [String: Any] = ["case":item.name,"width":rw,"height":rh,"tileSize":item.tileSize,"maxError":maxError,"alphaMaxError":alphaError,"rmse":rmse,"changedChannels":changed,"passed":passed]
                if item.performance && passed {
                    var before = [Double](), after = [Double]()
                    // 串行交錯七輪，彼此獨立清除快取；排除第一次編譯暖機。
                    for trial in 0..<7 {
                        if trial%2 == 0 {
                            before.append(try render(reference,referenceContext).1)
                            after.append(try render(shared,sharedContext).1)
                        } else {
                            after.append(try render(shared,sharedContext).1)
                            before.append(try render(reference,referenceContext).1)
                        }
                    }
                    row["referenceMilliseconds"] = before
                    row["sharedMilliseconds"] = after
                    row["referenceMedian"] = before.sorted()[3]
                    row["sharedMedian"] = after.sorted()[3]
                    let repeated = try render(shared,sharedContext).0
                    guard repeated == result else { throw failure("\(item.name)：相同輸入重複渲染不同") }
                }
                rows.append(row)
                print("\(item.name)：\(passed ? "通過" : "失敗")，最大差異 \(maxError)")
                fflush(stdout)
            }
        }
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed":passed,"device":device.name,"scope":"乳劑 Float32 捕獲場，同步 CPU 回讀；不含 RAW、後續顯影、成品或桌面快取。每次清除 CIContext 快取。","cases":rows]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[3]))
        guard passed else { throw failure("乳劑共用超出誤差門檻") }
    }
}
