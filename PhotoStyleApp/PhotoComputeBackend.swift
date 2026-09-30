import Foundation
import CoreImage
import PhotoStyleShared
import Darwin

/// 使用者只選運算方式；平台實作由路由器決定，不寫進照片的調整參數。
enum PhotoComputeBackend: String, Sendable {
    case system, vulkan
    static let defaultsKey = "computeBackend.v1"
    static func preference(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}

enum PhotoComputeStage: String { case development, chemistry, spectral, character, scanner, rawMapping, monochrome, blend }
struct PhotoComputeRequest: Encodable {
    let schema = 1
    let stage: String
    let effects: PhotoFilmEffects
    let strength: Double
    let monochrome: Bool
    let stock: String?
    let originX: Double
    let originY: Double
}

/// 0 是輸入影像；第 n 個節點產生影像 n+1。只允許引用較早的影像。
/// 分支（例如底片強度混合）仍留在 GPU，不需要把中間成品交回 Swift。
struct PhotoComputePlan: Encodable {
    struct Node: Encodable {
        var source: Int
        var secondary: Int?
        var operation: PhotoComputeRequest
    }
    let schema = 2
    var nodes: [Node] = []
    @discardableResult mutating func append(_ stage: PhotoComputeStage, source: Int, secondary: Int? = nil,
        effects: PhotoFilmEffects = .neutral, strength: Double = 1, monochrome: Bool = false,
        stock: PhotoFilmStock? = nil, origin: CGPoint = .zero) -> Int {
        if stage == .development && (effects.developmentAmount == 0 || strength == 0) { return source }
        if stage == .chemistry {
            var chemistry = effects.developerChemistry.clamped()
            if monochrome { chemistry.red = 0; chemistry.green = 0; chemistry.blue = 0 }
            if strength == 0 || chemistry == .neutral { return source }
        }
        nodes.append(Node(source: source, secondary: secondary, operation: PhotoComputeRequest(
            stage: stage.rawValue, effects: effects.clamped(), strength: strength, monochrome: monochrome,
            stock: stock?.rawValue, originX: origin.x, originY: origin.y)))
        return nodes.count
    }
}

/// 所有階段共用的中介契約。未移植階段由既有管線保留原生處理順序。
protocol PhotoComputeProvider {
    var route: String { get }
    var supportsResidentPlan: Bool { get }
    func apply(_ plan: PhotoComputePlan, to image: CIImage) throws -> CIImage
    func apply(_ stage: PhotoComputeStage, to image: CIImage, effects: PhotoFilmEffects,
               strength: Double, monochrome: Bool, stock: PhotoFilmStock?,
               native: () -> CIImage) throws -> CIImage
}
extension PhotoComputeProvider {
    var supportsResidentPlan: Bool { false }
    func apply(_ plan: PhotoComputePlan, to image: CIImage) throws -> CIImage {
        throw PhotoComputeError(detail: "此後端不支援 GPU 常駐計算圖")
    }
}
struct PhotoNativeComputeProvider: PhotoComputeProvider {
    let route = "mac-native"
    func apply(_ stage: PhotoComputeStage, to image: CIImage, effects: PhotoFilmEffects,
               strength: Double, monochrome: Bool, stock: PhotoFilmStock?,
               native: () -> CIImage) throws -> CIImage { native() }
}

enum PhotoBackendRouter {
    static func compute(_ backend: PhotoComputeBackend) throws -> any PhotoComputeProvider {
        switch backend {
        case .system: return PhotoNativeComputeProvider()
        case .vulkan: return try PhotoVulkanComputeProvider()
        }
    }
    // Windows 宿主將使用相同 PhotoCompute C ABI，連接 Vulkan loader；
    // 此 macOS 宿主只連接隨 App 打包的 MoltenVK，不依賴 Homebrew 執行環境。
    static func validate(_ backend: PhotoComputeBackend) throws { _ = try compute(backend) }
    /// 只移除快取擁有權；進行中的 provider 仍持有 engine，完成前不會銷毀 GPU。
    static func releaseIdleComputeResources() { PhotoVulkanEngine.releaseCached() }
}

struct PhotoComputeError: LocalizedError {
    let detail: String
    var errorDescription: String? { "Vulkan 加速無法完成：\(detail)" }
}

final class PhotoVulkanComputeProvider: PhotoComputeProvider {
    let route = "vulkan-mac"
    let supportsResidentPlan = true
    private let engine: PhotoVulkanEngine
    private let context = PhotoImageRenderPrecision.makeContext()
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    init() throws { engine = try PhotoVulkanEngine.acquire() }
    func apply(_ stage: PhotoComputeStage, to image: CIImage, effects: PhotoFilmEffects,
               strength: Double, monochrome: Bool, stock: PhotoFilmStock?,
               native: () -> CIImage) throws -> CIImage {
        try Task.checkCancellation()
        if stage == .development && (effects.developmentAmount == 0 || strength == 0) { return image }
        var effects = effects
        var image = image
        if stage == .spectral && effects.modernFilmExposureEnabled {
            // 未移植的自適應曝光在共用原生階段完成，Vulkan 收到已曝光的線性影像。
            image = PhotoFilmEffectsProcessor.applyExposure(to: image, effects: effects, renderContext: context)
            effects.clearPrintExposure()
            effects.modernFilmExposureEnabled = false
        }
        let packet = PhotoComputeRequest(stage: stage.rawValue, effects: effects.clamped(),
            strength: strength, monochrome: monochrome, stock: stock?.rawValue,
            originX: Double(image.extent.integral.minX), originY: Double(image.extent.integral.minY))
        return try process(packet, image: image)
    }
    func apply(_ plan: PhotoComputePlan, to image: CIImage) throws -> CIImage {
        guard !plan.nodes.isEmpty else { return image }
        return try process(plan, image: image)
    }
    private func process<Request: Encodable>(_ packet: Request, image: CIImage) throws -> CIImage {
        try Task.checkCancellation()
        let bounds = image.extent.integral
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width <= CGFloat(UInt32.max), bounds.height <= CGFloat(UInt32.max),
              bounds.width * bounds.height < CGFloat(Int.max / 16) else {
            throw PhotoComputeError(detail: "影像尺寸不合法")
        }
        let width = Int(bounds.width), height = Int(bounds.height)
        var input = Data(count: width * height * 16)
        input.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        // 與既有 C++ 相同：頂列在前，保留負值、高光、alpha，不做 SDR 量化。
        let output = try engine.process(input, width: width, height: height,
                                        request: String(decoding: JSONEncoder().encode(packet), as: UTF8.self))
        try Task.checkCancellation()
        return CIImage(bitmapData: output, bytesPerRow: width * 16, size: bounds.size,
                       format: .RGBAf, colorSpace: linear)
            .transformed(by: .init(translationX: bounds.minX, y: bounds.minY)).cropped(to: image.extent)
    }
}

private final class PhotoVulkanEngine: @unchecked Sendable {
    typealias ABI = @convention(c) () -> UInt32
    typealias Create = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> UnsafeMutableRawPointer?
    typealias Process = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<Float>?, UnsafeMutablePointer<Float>?, UInt32, UInt32, UnsafeMutablePointer<CChar>?, Int) -> Int32
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    // 持久化 device／pipeline／光譜 LUT；所有 GPU 工作序列化，避免預覽與批次同時重用資源。
    private static let cacheLock = NSLock()
    private static var cached: PhotoVulkanEngine?
    static func acquire() throws -> PhotoVulkanEngine {
        try cacheLock.withLock {
            if let cached { return cached }
            let engine = try PhotoVulkanEngine()
            cached = engine
            return engine
        }
    }
    static func releaseCached() {
        // destructor 可能等待 GPU；不可持有快取鎖進行銷毀。
        let released = cacheLock.withLock { () -> PhotoVulkanEngine? in
            let previous = cached
            cached = nil
            return previous
        }
        withExtendedLifetime(released) {}
    }
    private let library: UnsafeMutableRawPointer
    private let handle: UnsafeMutableRawPointer
    private let processFunction: Process
    private let destroyFunction: Destroy
    private let lock = NSLock()
    private init() throws {
        guard let resources = Bundle.main.resourceURL,
              let frameworks = Bundle.main.privateFrameworksURL else {
            throw PhotoComputeError(detail: "找不到 App 運算資源")
        }
        let directory = resources.appendingPathComponent("PhotoCompute", isDirectory: true)
        guard let library = dlopen(frameworks.appendingPathComponent("libPhotoCompute.dylib").path, RTLD_NOW | RTLD_LOCAL) else {
            throw PhotoComputeError(detail: "無法載入運算後端：" + (dlerror().map { String(cString: $0) } ?? "缺少程式庫"))
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw PhotoComputeError(detail: "運算介面缺件：\(name)") }
            return unsafeBitCast(address, to: type)
        }
        do {
            let abi = try symbol("photo_compute_abi", as: ABI.self)
            guard abi() == 2 else { throw PhotoComputeError(detail: "運算介面版本不符") }
            let create = try symbol("photo_compute_create", as: Create.self)
            let process = try symbol("photo_compute_process", as: Process.self)
            let destroy = try symbol("photo_compute_destroy", as: Destroy.self)
            var error = [CChar](repeating: 0, count: 2048)
            guard let handle = create(directory.appendingPathComponent("film-data").path,
                                      directory.appendingPathComponent("film.comp.spv").path, &error, error.count) else {
                throw PhotoComputeError(detail: String(cString: error))
            }
            self.library = library; self.handle = handle
            processFunction = process; destroyFunction = destroy
        } catch { dlclose(library); throw error }
    }
    deinit { destroyFunction(handle); dlclose(library) }
    func process(_ input: Data, width: Int, height: Int, request: String) throws -> Data {
        try lock.withLock {
            try Task.checkCancellation()
            var output = Data(count: input.count)
            var error = [CChar](repeating: 0, count: 2048)
            let status = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    processFunction(handle, request, source.bindMemory(to: Float.self).baseAddress,
                        destination.bindMemory(to: Float.self).baseAddress, UInt32(width), UInt32(height), &error, error.count)
                }
            }
            guard status == 0 else { throw PhotoComputeError(detail: String(cString: error)) }
            return output
        }
    }
}
