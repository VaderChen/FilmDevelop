import AppKit
import CoreImage
import CoreML
import CryptoKit
import PhotoStyleShared
import Vision

struct PhotoRepairStroke: Decodable, Sendable {
    struct Point: Decodable, Sendable { let x: Double; let y: Double }
    let radius: Double
    let points: [Point]
}

enum PhotoRepairError: LocalizedError {
    case invalidMask, invalidModel, downloadFailed, tooManyRepairs
    var errorDescription: String? {
        switch self {
        case .invalidMask: return "請先在照片上塗抹要修復的區域。"
        case .invalidModel: return "修復模型無法使用，請稍後重試。"
        case .downloadFailed: return "修復模型下載失敗，請檢查網路後重試。"
        case .tooManyRepairs: return "這張照片的修復次數已達上限，請先匯出成品再繼續。"
        }
    }
}

struct PhotoRepairModelProgress: Sendable {
    let received: Int64
    let total: Int64
    var preparing = false
    var payload: [String: Any] { ["received": received, "total": total, "preparing": preparing] }
}

actor PhotoRepairService {
    static let shared = PhotoRepairService()
    private var model: MLModel?
    private let context = PhotoImageRenderPrecision.makeContext()
    private static let revision = "5ed76e3799ab4cad31381750d29880c267477e18"
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStyleApp/RepairModels/LaMa-\(revision)", isDirectory: true)
    }
    private let modelDirectory: URL
    init(directory: URL = PhotoRepairService.directory) { modelDirectory = directory }

    func repair(source: PhotoImage, patches: [PhotoRepairPatch], strokes: [PhotoRepairStroke],
                downloadProgress: @escaping @Sendable (PhotoRepairModelProgress?) -> Void = { _ in },
                progress: @Sendable (String) -> Void) async throws -> PhotoRepairPatch {
        guard !strokes.isEmpty, strokes.count <= 128,
              strokes.reduce(0, { $0 + $1.points.count }) <= 20_000,
              strokes.allSatisfy({ stroke in
                  stroke.radius.isFinite && stroke.radius > 0 && stroke.radius <= 0.5 && !stroke.points.isEmpty
                    && stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
              }), let decoded = CIImage(image: source) else { throw PhotoRepairError.invalidMask }
        try Task.checkCancellation()
        let model = try await loadModel(progress: progress, downloadProgress: downloadProgress)
        progress("正在修復塗抹區域…")
        let image = PhotoRepairPatch.applying(patches, to: decoded.oriented(source.imageOrientation))
        let extent = image.extent
        var painted = CGRect.null
        for stroke in strokes {
            let radius = stroke.radius * extent.width
            for p in stroke.points {
                let point = CGPoint(x: extent.minX + p.x * extent.width, y: extent.maxY - p.y * extent.height)
                painted = painted.union(CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2))
            }
        }
        let margin = max(64, max(painted.width, painted.height) * 0.5)
        let roi = painted.insetBy(dx: -margin, dy: -margin).intersection(extent).integral.intersection(extent)
        guard !roi.isEmpty, roi.width > 0, roi.height > 0,
              let imageConstraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let maskConstraint = model.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint else { throw PhotoRepairError.invalidModel }
        let width = imageConstraint.pixelsWide, height = imageConstraint.pixelsHigh
        guard width == maskConstraint.pixelsWide, height == maskConstraint.pixelsHigh else { throw PhotoRepairError.invalidModel }
        let scale = min(CGFloat(width)/roi.width, CGFloat(height)/roi.height)
        let fit = CGRect(x: (CGFloat(width)-roi.width*scale)/2, y: (CGFloat(height)-roi.height*scale)/2,
                         width: roi.width*scale, height: roi.height*scale)
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: fit.minX-roi.minX*scale, ty: fit.minY-roi.minY*scale)
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let resized = image.cropped(to: roi).transformed(by: transform).clampedToExtent().cropped(to: target)
        // 用可還原的曝光縮放保留 RAW 高光；模型以 sRGB 影像運作。
        let maximum = resized.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: target)])
        var peak = [Float](repeating: 0, count: 4)
        context.render(maximum, toBitmap: &peak, rowBytes: 16, bounds: CGRect(x: 0,y: 0,width: 1,height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let gain = max(1, Double(peak.prefix(3).filter(\.isFinite).max() ?? 1))
        let normalized = resized.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -log2(gain)])
        guard let cgImage = context.createCGImage(normalized, from: target, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw PhotoRepairError.invalidMask }
        maskContext.setFillColor(gray: 0, alpha: 1); maskContext.fill(target)
        maskContext.setStrokeColor(gray: 1, alpha: 1); maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.setLineCap(.round); maskContext.setLineJoin(.round)
        for stroke in strokes {
            let radius = max(1, stroke.radius * extent.width * scale)
            let points = stroke.points.map { CGPoint(x: extent.minX + $0.x*extent.width, y: extent.maxY - $0.y*extent.height).applying(transform) }
            maskContext.setLineWidth(radius*2)
            if points.count == 1 {
                maskContext.fillEllipse(in: CGRect(x: points[0].x-radius,y: points[0].y-radius,width: radius*2,height: radius*2))
            } else {
                maskContext.beginPath(); maskContext.move(to: points[0]); points.dropFirst().forEach { maskContext.addLine(to: $0) }; maskContext.strokePath()
            }
        }
        guard let maskCG = maskContext.makeImage() else { throw PhotoRepairError.invalidMask }
        let options: [MLFeatureValue.ImageOption: Any] = [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": try MLFeatureValue(cgImage: cgImage, constraint: imageConstraint, options: options),
            "mask": try MLFeatureValue(cgImage: maskCG, constraint: maskConstraint, options: options)
        ])
        try Task.checkCancellation()
        let output = try await model.prediction(from: input)
        guard let buffer = output.featureNames.compactMap({ output.featureValue(for: $0)?.imageBufferValue }).first else { throw PhotoRepairError.invalidModel }
        let repaired = CIImage(cvPixelBuffer: buffer).cropped(to: fit)
        let softMask = CIImage(cgImage: maskCG, options: [.colorSpace: NSNull()])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8]).cropped(to: fit)
        guard let imageData = context.pngRepresentation(of: repaired, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let maskData = context.pngRepresentation(of: softMask, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) else { throw PhotoRepairError.invalidModel }
        try Task.checkCancellation()
        return PhotoRepairPatch(x: (roi.minX-extent.minX)/extent.width, y: (roi.minY-extent.minY)/extent.height,
                                width: roi.width/extent.width, height: roi.height/extent.height,
                                imageData: imageData, maskData: maskData, linearGain: gain)
    }

    func prepare(downloadProgress: @escaping @Sendable (PhotoRepairModelProgress?) -> Void,
                 progress: @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        _ = try await loadModel(progress: progress, downloadProgress: downloadProgress)
        try Task.checkCancellation()
    }

    private func loadModel(progress: @Sendable (String) -> Void, downloadProgress: @escaping @Sendable (PhotoRepairModelProgress?) -> Void) async throws -> MLModel {
        if let model { return model }
        let compiled = modelDirectory.appendingPathComponent("LaMa.mlmodelc")
        let configuration = MLModelConfiguration()
        #if arch(arm64)
        configuration.computeUnits = .cpuAndGPU
        #else
        configuration.computeUnits = .cpuOnly
        #endif
        if FileManager.default.fileExists(atPath: compiled.path), let model = try? MLModel(contentsOf: compiled, configuration: configuration) {
            self.model = model; return model
        }
        let files: [(String, String, Int64)] = [
            ("Manifest.json", "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58", 617),
            ("Data/com.apple.CoreML/model.mlmodel", "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953", 1101809),
            ("Data/com.apple.CoreML/weights/weight.bin", "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184", 215544960)
        ]
        let package = modelDirectory.appendingPathComponent("LaMa.mlpackage")
        let total = files.reduce(Int64(0)) { $0 + $1.2 }
        var completed: Int64 = 0
        downloadProgress(.init(received: 0, total: total))
        for (name, digest, size) in files {
            try Task.checkCancellation()
            let target = package.appendingPathComponent(name)
            if Self.matchesDigest(target, digest) { completed += size; downloadProgress(.init(received: completed, total: total)); continue }
            progress("首次使用：正在下載修復模型（約 217 MB）…")
            let url = URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/\(Self.revision)/LaMa.mlpackage/\(name)")!
            let previous = completed
            let transfer = PhotoRepairTransfer { received, _ in
                downloadProgress(.init(received: previous + min(received, size), total: total))
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let response = try await transfer.download(URLRequest(url: url), to: temporary)
            guard (response as? HTTPURLResponse)?.statusCode == 200, Self.matchesDigest(temporary, digest) else { throw PhotoRepairError.downloadFailed }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += size
            downloadProgress(.init(received: completed, total: total))
        }
        progress("正在準備本機修復工具…")
        downloadProgress(.init(received: total, total: total, preparing: true))
        let result = try await MLModel.compileModel(at: package)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: compiled.path) { try FileManager.default.removeItem(at: compiled) }
        try FileManager.default.copyItem(at: result, to: compiled)
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        self.model = model
        downloadProgress(nil)
        return model
    }

    private static func matchesDigest(_ url: URL, _ expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined() == expected
        } catch { return false }
    }
}

// 使用 session delegate 回報實際下載位元組，取消時同步結束傳輸。
final class PhotoRepairTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var destination: URL?
    private var result: Result<URLResponse, Error>?
    private var cancelled = false
    private var createdDestination = false
    private var lastProgressTime = Date.distantPast
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressTime) >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastProgressTime = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    // Session-level download callbacks deliver byte progress reliably; the async
    // URLSession convenience method only forwards task-level delegate events.
    func download(_ request: URLRequest, to destination: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.destination = destination
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 1800
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                downloadSession = session; downloadTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.downloadTask
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination, let response = downloadTask.response else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            createdDestination = true
            result = .success(response)
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let outcome = cancelled ? Result<URLResponse, Error>.failure(CancellationError())
            : error.map { .failure($0) } ?? result ?? .failure(URLError(.badServerResponse))
        let downloadSession = self.downloadSession
        self.downloadSession = nil; downloadTask = nil
        lock.unlock()
        if case .failure = outcome, createdDestination, let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        continuation?.resume(with: outcome)
        downloadSession?.finishTasksAndInvalidate()
    }
}
