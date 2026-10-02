import Foundation
import CoreImage
import ImageIO

// 比較解碼後的 sRGB Float32 像素，避免壓縮方式或中繼資料造成誤判。
let context = CIContext(options: [.useSoftwareRenderer: true])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func pixels(_ path: String) throws -> (Int, Int, [Float]) {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
        throw NSError(domain: "影像無法解碼", code: 1)
    }
    let w = Int(image.extent.width), h = Int(image.extent.height)
    var data = [Float](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { bytes in
        context.render(image, toBitmap: bytes.baseAddress!, rowBytes: w * 16,
                       bounds: image.extent, format: .RGBAf, colorSpace: space)
    }
    return (w, h, data)
}
do {
    let a = try pixels(CommandLine.arguments[1]), b = try pixels(CommandLine.arguments[2])
    guard a.0 == b.0, a.1 == b.1 else { throw NSError(domain: "影像尺寸不同", code: 2) }
    var maxError: Float = 0, squared = 0.0, changed = 0
    for (x,y) in zip(a.2,b.2) {
        guard x.isFinite, y.isFinite else { throw NSError(domain: "影像含有非有限數值", code: 3) }
        let delta = abs(x-y)
        maxError = max(maxError, delta); squared += Double(delta * delta)
        if delta > 0 { changed += 1 }
    }
    let result: [String: Any] = ["width": a.0, "height": a.1, "maxError": maxError,
                                "rmse": sqrt(squared / Double(a.2.count)), "changedChannels": changed]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
} catch { fputs("\(error)\n", stderr); exit(1) }
