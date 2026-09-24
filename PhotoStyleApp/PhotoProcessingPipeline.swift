import CoreImage
import Foundation
import OSLog

/// Each stage reads a completed bitmap and writes the other buffer. No stage
/// may retain an input image/graph after its closure returns. This prevents an
/// HDR/mask branch from replaying the entire history of preceding filters.
final class PhotoProcessingPipeline {
    private let progress: ((String, Double) -> Void)?
    let context = PhotoImageRenderPrecision.makeContext()
    private let colorSpace: CGColorSpace
    private var source: CIImage?
    private var current: Buffer?
    private var spare: Buffer?
    private static let logger = Logger(subsystem: "person.vader.PhotoStyleApp", category: "ImageProcessing")
    private static let profilesMemory = ProcessInfo.processInfo.environment["PHOTO_PROFILE_NATIVE"] == "1"

    init(source: CIImage, colorSpace: CGColorSpace,
         progress: ((String, Double) -> Void)? = nil) {
        self.progress = progress
        self.source = source
        self.colorSpace = colorSpace
    }

    private func inputImage() throws -> CIImage {
        if let current, let bitmap = current.image(colorSpace: colorSpace) {
            return CIImage(cgImage: bitmap).transformed(by: .init(translationX: current.bounds.minX, y: current.bounds.minY))
        }
        guard let source else { throw Failure.render }
        return source
    }

    func process(_ name: String, _ transform: (CIImage) -> CIImage) throws {
        try Task.checkCancellation()
        memory(name + ".begin")
        progress?(name, 0)
        let start = ProcessInfo.processInfo.systemUptime
        let result: Buffer? = try autoreleasepool {
            let input = try inputImage()
            let graph = transform(input)
            guard graph !== input else { return nil }
            let bounds = graph.extent.integral
            let destination = try spare?.resized(to: bounds) ?? Buffer(bounds: bounds)
            try destination.render(graph, context: context, colorSpace: colorSpace,
                progress: { self.progress?(name, $0) })
            return destination
        }
        if let result {
            spare = current
            current = result
            source = nil
        }
        // The graph and all temporary images above have left the pool. Complete
        // CPU readback precedes reuse of either buffer on the following stage.
        context.clearCaches()
        Self.logger.debug("Stage \(name, privacy: .public): \(ProcessInfo.processInfo.systemUptime-start) seconds")
        memory(name + ".end")
        progress?(name, 1)
    }

    /// Statistics and masks must return independent values, not a graph that
    /// references a reusable input buffer.
    func inspect<T>(_ name: String, _ body: (CIImage) throws -> T) throws -> T {
        try Task.checkCancellation()
        memory(name + ".begin")
        progress?(name, 0)
        let value = try autoreleasepool { try body(inputImage()) }
        context.clearCaches()
        memory(name + ".end")
        progress?(name, 1)
        return value
    }

    func finish() throws -> PhotoImage {
        defer { spare = nil; context.clearCaches() }
        if let current, let bitmap = current.image(colorSpace: colorSpace) {
            return PhotoImage(cgImage: bitmap)
        }
        guard let image = source,
              let output = PhotoImageRenderPrecision.renderedImage(from: image, context: context,
                highPrecision: false, colorSpace: colorSpace, deferred: false) else { throw Failure.render }
        return output
    }

    /// A skin mask survives several stages, but needs only one Float32 channel.
    func mask(_ image: CIImage) throws -> CIImage {
        let bounds = image.extent.integral
        _ = try Buffer.byteCount(bounds)
        let rowBytes = Int(bounds.width) * MemoryLayout<Float>.size
        var data = Data(count: rowBytes * Int(bounds.height))
        try data.withUnsafeMutableBytes { bytes in
            try Self.render(image, context: context, bitmap: bytes.baseAddress!, rowBytes: rowBytes,
                            bounds: bounds, format: .Rf, bytesPerPixel: 4, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: bounds.size, format: .Rf, colorSpace: nil)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)
            ])
            .transformed(by: .init(translationX: bounds.minX, y: bounds.minY)).cropped(to: image.extent)
    }

    // Tiles bound only the scratch space within one stage. Buffer ownership and
    // stage barriers are the same whether this loop runs once or many times.
    private static func render(_ image: CIImage, context: CIContext, bitmap: UnsafeMutableRawPointer,
                               rowBytes: Int, bounds: CGRect, format: CIFormat, bytesPerPixel: Int,
                               colorSpace: CGColorSpace?,
                               progress: ((Double) -> Void)? = nil) throws {
        let width = Int(bounds.width), height = Int(bounds.height)
        let edge = 512
        let columns = (width + edge - 1) / edge
        let count = columns * ((height + edge - 1) / edge)
        func renderTile(_ index: Int) {
            let x = (index % columns) * edge, y = (index / columns) * edge
            let w = min(edge, width-x), h = min(edge, height-y)
            autoreleasepool {
                context.render(image, toBitmap: bitmap.advanced(by: y*rowBytes+x*bytesPerPixel), rowBytes: rowBytes,
                    bounds: CGRect(x: bounds.minX+CGFloat(x), y: bounds.maxY-CGFloat(y+h), width: CGFloat(w), height: CGFloat(h)),
                    format: format, colorSpace: colorSpace)
            }
        }
        // Metal parallelizes pixels within the stage. Concurrent CPU tile
        // submissions showed no speedup, so keep scratch usage bounded here.
        for index in 0..<count {
            try Task.checkCancellation()
            renderTile(index)
            progress?(Double(index + 1) / Double(count))
        }
    }

    private func memory(_ stage: String) {
        guard Self.profilesMemory else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let row: [String: Any] = ["stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
            "footprint": info.phys_footprint, "resident": info.resident_size, "processPeak": info.ledger_phys_footprint_peak]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("STAGE " + text) }
    }

    private enum Failure: Error { case render, invalidSize }

    private final class Buffer {
        private let pixels: UnsafeMutableRawPointer
        private let capacity: Int
        fileprivate var bounds: CGRect
        private var rowBytes: Int { Int(bounds.width) * 16 }

        init(bounds: CGRect) throws {
            let size = try Self.byteCount(bounds)
            guard let pixels = malloc(size) else { throw Failure.render }
            self.pixels = pixels; capacity = size; self.bounds = bounds
        }
        deinit { free(pixels) }
        fileprivate static func byteCount(_ bounds: CGRect) throws -> Int {
            guard !bounds.isEmpty, !bounds.isInfinite,
                  [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite),
                  bounds.width < CGFloat(Int.max/16), bounds.height < CGFloat(Int.max)/bounds.width/16 else { throw Failure.invalidSize }
            return Int(bounds.width) * Int(bounds.height) * 16
        }
        func resized(to bounds: CGRect) throws -> Buffer {
            if try Self.byteCount(bounds) <= capacity { self.bounds = bounds; return self }
            return try Buffer(bounds: bounds)
        }
        func render(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace, progress: ((Double) -> Void)?) throws {
            try PhotoProcessingPipeline.render(image, context: context, bitmap: pixels, rowBytes: rowBytes,
                bounds: bounds, format: .RGBAf, bytesPerPixel: 16, colorSpace: colorSpace, progress: progress)
        }
        func image(colorSpace: CGColorSpace) -> CGImage? {
            let owner = Unmanaged.passRetained(self).toOpaque()
            guard let provider = CGDataProvider(dataInfo: owner, data: pixels, size: rowBytes * Int(bounds.height),
                releaseData: { owner, _, _ in
                    if let owner { Unmanaged<Buffer>.fromOpaque(owner).release() }
                }) else { Unmanaged<Buffer>.fromOpaque(owner).release(); return nil }
            return CGImage(width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 32,
                bitsPerPixel: 128, bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}
