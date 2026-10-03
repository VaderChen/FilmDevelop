import Foundation
import AppKit
import CoreImage
import ImageIO
import PhotoStyleShared
import CryptoKit
import SQLite3

struct WorkerFailure: Error {
    let code: String
    let message: String
}

/// Go 排程、取消與發布；預覽工作階段只保留目前照片的原生影像資源。
@main enum NativeWorker {
    final class PreviewCache {
        var key = ""
        var source: PhotoImage?
        var sourcePurpose: PhotoRAWDecodePurpose?
        // 同時保留編輯縮圖與清晰處理圖；切換手勢不用反覆縮放同一張 RAW。
        // 每張照片至多兩份，來源或 RAW 設定改變時整個快取一起替換。
        var processing: [(size: Int, image: PhotoImage)] = []
        var mask: CIImage?
        var maskKey: String?
        var comparisons: [(key: String, image: String)] = []
        var editors: [(key: String, image: String)] = []
        let stages = PhotoProcessingPipeline.Cache()
    }
    // 不含裁切與裝飾，但保留所有會改變來源編輯圖的運算條件。
    struct EditorCacheKey: Encodable {
        let style: String
        let adjustment: StyleAdjustment
        let repairs: JSONValue
        let maskKey: String?
        let detectSubject: Bool
        let computeBackend: String
        let policy: RenderPolicy?
        let maxPixel: Int
    }
    static var previewCache = PreviewCache()
    final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func update(_ progress: Double) { lock.lock(); defer { lock.unlock() }; if progress == 1 { value = true } }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let outputLock = NSLock()
    static func emit(_ response: Response) throws {
        var data = try JSONEncoder().encode(response)
        guard data.count < EngineProtocol.maxMessageBytes else {
            throw WorkerFailure(code: "responseTooLarge", message: "引擎回覆超過大小限制")
        }
        data.append(10)
        outputLock.lock(); defer { outputLock.unlock() }
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    static func payload(_ value: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func main() async {
        var id = ""
        do {
            var input = Data()
            let session = CommandLine.arguments.dropFirst() == ["--preview-session"]
            while true {
                // 工作階段不能等待讀滿 64 KiB 或 EOF，須立即處理目前管線資料。
                let chunk = session ? FileHandle.standardInput.availableData
                    : (try FileHandle.standardInput.read(upToCount: 65536) ?? Data())
                if chunk.isEmpty { break }
                input.append(chunk)
                if session {
                    while let end = input.firstIndex(of: 10) {
                        let line = Data(input[..<end])
                        input.removeSubrange(...end)
                        guard line.count < EngineProtocol.maxMessageBytes else {
                            throw WorkerFailure(code: "requestTooLarge", message: "引擎請求超過大小限制")
                        }
                        let request = try readRequest(line, id: &id)
                        guard request.method == "preview" else {
                            throw WorkerFailure(code: "invalidRequest", message: "預覽工作階段僅接受預覽工作")
                        }
                        let result = try await execute(request)
                        try emit(Response(version: EngineProtocol.version, id: id, kind: "result", payload: result, error: nil))
                    }
                }
                guard input.count <= EngineProtocol.maxMessageBytes else {
                    throw WorkerFailure(code: "requestTooLarge", message: "引擎請求超過大小限制")
                }
            }
            if session {
                guard input.isEmpty else { throw WorkerFailure(code: "invalidRequest", message: "預覽請求未完整結束") }
                return
            }
            let request = try readRequest(input, id: &id)
            let result = try await execute(request)
            try emit(Response(version: EngineProtocol.version, id: id, kind: "result", payload: result, error: nil))
        } catch {
            let failure = error as? WorkerFailure ?? WorkerFailure(code: "nativeFailure", message: error.localizedDescription)
            try? emit(Response(version: EngineProtocol.version, id: id, kind: "error", payload: .null,
                               error: EngineError(code: failure.code, message: failure.message)))
            exit(1)
        }
    }
    static func readRequest(_ input: Data, id: inout String) throws -> Request {
        let request = try JSONDecoder().decode(Request.self, from: input)
        id = request.id
        guard try JSONDecoder().decode(JSONValue.self, from: input) == .from(request) else {
            throw WorkerFailure(code: "invalidRequest", message: "請求包含未知欄位")
        }
        guard request.version == EngineProtocol.version else {
            throw WorkerFailure(code: "unsupportedVersion", message: "不支援此引擎契約版本")
        }
        return request
    }
    static func execute(_ request: Request) async throws -> JSONValue {
        switch request.method {
        case "capabilities":
            var compute = ["system"]
            if (try? PhotoBackendRouter.validate(.vulkan)) != nil { compute.append("vulkan") }
            return try payload([
                "platform": "darwin-arm64", "engine": "swift-native", "protocolVersion": 1,
                "recipeVersion": 1, "adjustmentVersion": 12,
                "methods": ["capabilities", "render", "preview", "thumbnail", "whiteBalance", "metadata", "rawProbe", "reveal", "trash", "analysis", "infer", "prepareRepair", "repair"],
                "mlx": FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MLX/photostyle-mlx").path),
                "computeBackends": compute, "rawDecoders": ["system", "software"],
                "formats": PhotoExportFormat.allCases.map { ["id": $0.rawValue, "bitDepths": $0.supportedBitDepths] },
                "features": ["full-render-pipeline", "subject-mask", "saved-repair-patches", "color-managed-export"],
                "limitations": ["預覽快取只保留目前照片；取消或閒置回收後重新建立"]
            ])
        case "analysis":
            let value = try strictPayload(request.payload, as: AnalysisRequest.self)
            let image = try sourceImage(value.input)
            let patches = try value.recipe.repairPatches.decoded([PhotoRepairPatch].self)
            let prepared = PhotoStyleProcessor.repairedSource(image, patches: patches).resizedForWebPreview(maxPixel: 800)
            guard let data = prepared.jpegData(compressionQuality: 0.88) else { throw WorkerFailure(code: "analysisFailed", message: "無法準備分析照片") }
            return try payload(["imageData": data.base64EncodedString(), "analysis": PhotoStyleAdjustmentMapper.imageAnalysisSummary(for: prepared) ?? ""])
        case "infer":
            let value = try strictPayload(request.payload, as: InferenceRequest.self)
            guard value.format == "gguf", (1...4096).contains(value.maxTokens), (4096...16384).contains(value.contextLimit),
                  let data = Data(base64Encoded: value.imageData) else { throw WorkerFailure(code: "invalidRequest", message: "推論參數無效") }
            let text = try await PhotoStyleLLMRuntime().generateText(imageData: data, modelPath: value.modelPath,
                projectorPath: value.projectorPath, systemPrompt: value.systemPrompt, userPrompt: value.userPrompt,
                grammar: value.grammar, maxTokens: value.maxTokens, contextLimit: value.contextLimit, progress: { progress in
                    try? emit(Response(version: 1, id: request.id, kind: "progress", payload: .number(Double(progress.rawValue) / 7), error: nil))
                })
            return try payload(["text": text])
        case "prepareRepair":
            let value = try strictPayload(request.payload, as: FileRequest.self)
            try await PhotoRepairService(directory: URL(fileURLWithPath: value.path)).prepare(downloadProgress: { _ in }, progress: { _ in })
            return try payload(["ready": true])
        case "repair":
            let value = try strictPayload(request.payload, as: RepairRequest.self)
            let patches = try value.recipe.repairPatches.decoded([PhotoRepairPatch].self)
            guard patches.count < 32 else { throw PhotoRepairError.tooManyRepairs }
            let patch = try await PhotoRepairService(directory: URL(fileURLWithPath: value.modelDirectory)).repair(
                source: sourceImage(value.input), patches: patches, strokes: value.strokes.decoded([PhotoRepairStroke].self), progress: { _ in })
            return try .from(patch)
        case "render":
            return try autoreleasepool { try render(strictPayload(request.payload, as: RenderJob.self), id: request.id) }
        case "preview":
            let job = try strictPayload(request.payload, as: RenderJob.self)
            guard job.preview else { throw WorkerFailure(code: "invalidRequest", message: "預覽工作不得用於匯出") }
            return try autoreleasepool { try render(job, id: request.id, useCache: true) }
        case "thumbnail":
            return try thumbnail(strictPayload(request.payload, as: ThumbnailRequest.self))
        case "legacySettings":
            let defaults = UserDefaults(suiteName: "person.vader.PhotoStyleApp")!
            let prefixes = ["photoStyle.ai.", "photoExport", "showAllFilms.", "exposureExpansionEnabled.",
                "modernFilmExposureEnabled.", "highlightProtectionEnabled.", "lensCorrectionEnabled.",
                "hdrFeatureEnabled.", "originalResolutionEditing.", "computeBackend.", "rawDecoderBackend.",
                "styleAdjustments.", "interfaceLanguage.", "mcpEnabled.", "lastSourceImage", "stylePrompts.", "promptLanguage.", "defaultExportDirectory.path.", "lastPhotoDirectoryPath.", "lastImageImportFilePath.", "recentPhotoDirectories."]
            var values: [String: Any] = [:]
            for (key, value) in defaults.dictionaryRepresentation() where prefixes.contains(where: key.hasPrefix) {
                if let bytes = value as? Data {
                    if let json = try? JSONSerialization.jsonObject(with: bytes) { values[key] = json }
                } else if JSONSerialization.isValidJSONObject([key: value]) { values[key] = value }
            }
            let bookmarks = ["lastImageImportFileBookmark.v1": "lastImageImportFilePath.v1",
                "lastPhotoDirectoryBookmark.v1": "lastPhotoDirectoryPath.v1",
                "photoStyle.ai.modelDirectory.bookmark": "photoStyle.ai.modelDirectory.path",
                "defaultExportDirectory.bookmark.v1": "defaultExportDirectory.path.v1"]
            var resolvedPaths:[[String:Any]] = []
            for (bookmark, path) in bookmarks {
                if let bytes = defaults.data(forKey: bookmark), let url = resolveLegacyBookmark(bytes) {
                    if let previous = values[path] as? String, previous != url.path { resolvedPaths.append(["from":previous,"to":url.path,"directory":bookmark != "lastImageImportFileBookmark.v1"]) }
                    values[path] = url.path
                }
            }
            if let entries = values["recentPhotoDirectories.v1"] as? [[String:Any]] {
                values["recentPhotoDirectories.v1"] = entries.map { entry -> [String:Any] in
                    var result: [String:Any] = [:]
                    result["path"] = entry["path"]
                    if let text = entry["bookmark"] as? String, let bytes = Data(base64Encoded:text), let url = resolveLegacyBookmark(bytes) {
                        if let previous = entry["path"] as? String, previous != url.path { resolvedPaths.append(["from":previous,"to":url.path,"directory":true]) }
                        result["path"] = url.path
                    }
                    return result
                }
            }
            // 僅在確有舊版設定時沿用 Swift 的預設值。
            if defaults.persistentDomain(forName: "person.vader.PhotoStyleApp") != nil {
                if values["interfaceLanguage.v1"] == nil { values["interfaceLanguage.v1"] = "automatic" }
                if values["mcpEnabled.v1"] == nil { values["mcpEnabled.v1"] = true }
            }
            values["resolvedPaths"] = resolvedPaths
            values["webPreferences"] = legacyWebPreferences()
            return try payload(values)
        case "rawProbe":
            let value = try strictPayload(request.payload, as: FileRequest.self)
            let url = URL(fileURLWithPath: value.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_073_741_824 else {
                throw WorkerFailure(code: "invalidRequest", message: "RAW 來源無法讀取或過大")
            }
            return try payload(PhotoSoftwareRAWDecoder.probe(data: Data(contentsOf: url, options: .mappedIfSafe)))
        case "metadata":
            let value = try strictPayload(request.payload, as: FileRequest.self)
            let url = URL(fileURLWithPath: value.path)
            var properties: [String: Any] = [:]
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            }
            // ImageIO 對部分舊 RAW 沒有完整拍攝欄位；以解碼器資料補齊，不把修改時間當拍攝時間。
            let exif = properties["{Exif}"] as? [String: Any] ?? [:]
            if exif["DateTimeOriginal"] == nil,
               let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 1_073_741_824,
               let raw = PhotoSoftwareRAWDecoder.metadata(data: data) {
                // 共用的拍攝欄位優先採 LibRaw，避免兩平台對 CIFF 曝光值的換算不同。
                for (key, field) in raw { properties[key] = field }
            }
            guard !properties.isEmpty else {
                throw WorkerFailure(code: "metadataFailed", message: "無法讀取照片資訊")
            }
            return try payload(jsonProperties(properties))
        case "reveal", "trash":
            let value = try strictPayload(request.payload, as: FileRequest.self)
            let url = URL(fileURLWithPath: value.path)
            if request.method == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            return try payload(["success": true])
        case "whiteBalance":
            let value = try strictPayload(request.payload, as: WhiteBalanceRequest.self)
            guard let result = PhotoToneProcessor.neutralBalance(sRGB: [value.red, value.green, value.blue],
                warmth: value.warmth, tint: value.tint, strength: value.strength) else {
                throw WorkerFailure(code: "invalidSample", message: "此處過暗或已過曝，請改選灰色或白色區域。")
            }
            return try payload(["warmth": result.warmth, "tint": result.tint])
        default:
            throw WorkerFailure(code: "unsupportedMethod", message: "不支援的引擎操作：\(request.method)")
        }
    }

    // 平台層只解析原生容器；取捨、版本及保存由 Go 決定。
    static func resolveLegacyBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData:data, options:[.withoutUI, .withoutMounting], relativeTo:nil, bookmarkDataIsStale:&stale)
    }
    static func legacyWebPreferences() -> [String:String] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/person.vader.PhotoStyleApp/WebsiteData")
        guard let enumerator = FileManager.default.enumerator(at:root, includingPropertiesForKeys:[.contentModificationDateKey], options:[.skipsHiddenFiles]) else { return [:] }
        var files:[URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "localstorage.sqlite3" { files.append(url) }
        files.sort { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var result:[String:String] = [:]
        for file in files {
            var db:OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; continue }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 500)
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT key,value FROM ItemTable LIMIT 256", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawKey = sqlite3_column_text(statement,0) else { continue }
                let key = String(cString:rawKey), count = Int(sqlite3_column_bytes(statement,1))
                guard key.hasPrefix("photoStyle."), count <= 131072, let bytes = sqlite3_column_blob(statement,1) else { continue }
                let data = Data(bytes:bytes,count:count)
                if let value = String(data:data,encoding:.utf16LittleEndian) { result[key] = value }
            }
        }
        return result
    }
    static func savedSubjectMask(_ input: SubjectMaskInput) throws -> CIImage {
        let data = try Data(contentsOf:URL(fileURLWithPath:input.path), options:.mappedIfSafe)
        guard data.count >= 16, data.count <= 268435472, data.prefix(8) == Data("FYPMASK1".utf8),
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == input.sha256 else { throw WorkerFailure(code:"invalidMask", message:"主體遮罩完整性檢查失敗") }
        func dimension(_ start:Int) -> Int { data[start..<start+4].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset*8) } }
        let width = dimension(8), height = dimension(12)
        guard width > 0, height > 0, width <= 4096, height <= 4096, data.count == 16+width*height*16 else { throw WorkerFailure(code:"invalidMask", message:"主體遮罩尺寸錯誤") }
        let finite = data.withUnsafeBytes { bytes in
            stride(from:16,to:data.count,by:4).allSatisfy { offset in Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self))).isFinite }
        }
        guard finite else { throw WorkerFailure(code:"invalidMask",message:"主體遮罩含非有限權重") }
        return CIImage(bitmapData:data.subdata(in:16..<data.count),bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
    }

    static func sourceImage(_ input: ImageInput) throws -> PhotoImage {
        let url = URL(fileURLWithPath: input.path)
        return try decodeSource(input, data: Data(contentsOf: url, options: .mappedIfSafe), url: url, purpose: .completeWithPreview)
    }

    static func decodeSource(_ input: ImageInput, data: Data, url: URL, purpose: PhotoRAWDecodePurpose) throws -> PhotoImage {
        guard let backend = PhotoRAWBackend(rawValue: input.rawDecoder) else {
            throw WorkerFailure(code: "invalidRequest", message: "RAW 解析設定不符")
        }
        // 明確選擇 LibRaw 時，由 Go 補足缺少的感光解碼器，避免悄悄改用另一套色彩處理。
        if backend == .software, PhotoSoftwareRAWDecoder.probe(data: data)["supported"] as? Bool == false {
            throw WorkerFailure(code: "rawConversionRequired", message: "此 RAW 壓縮方式需要補充解碼器")
        }
        guard let image = PhotoBackendRouter.decode(data: data, url: url, backend: backend,
                                                   lensCorrection: input.lensCorrection, purpose: purpose) else {
            if PhotoSoftwareRAWDecoder.probe(data: data)["supported"] as? Bool == false {
                throw WorkerFailure(code: "rawConversionRequired", message: "此 RAW 壓縮方式需要補充解碼器")
            }
            throw WorkerFailure(code: "decodeFailed", message: "無法解碼來源照片")
        }
        return image
    }

    // Go 管理目錄與快取；此入口只解碼小型顯示影像，RAW 優先讀取相機內嵌預覽。
    static func thumbnail(_ request: ThumbnailRequest) throws -> JSONValue {
        guard (32...512).contains(request.maxPixel) else {
            throw WorkerFailure(code: "invalidRequest", message: "縮圖大小不符")
        }
        let url = URL(fileURLWithPath: request.path)
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw WorkerFailure(code: "invalidRequest", message: "縮圖來源必須是一般影像檔案")
        }
        var bitmap = PhotoRAWThumbnail.make(from: url, maxPixel: request.maxPixel)
        if bitmap == nil, let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) {
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            if bitmap == nil {
                options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
                bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
        }
        let data = NSMutableData()
        guard let bitmap,
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw WorkerFailure(code: "decodeFailed", message: "無法讀取此照片的縮圖")
        }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 2 * 1024 * 1024 else {
            throw WorkerFailure(code: "encodeFailed", message: "無法產生照片縮圖")
        }
        return try .from(ThumbnailResult(imageData: (data as Data).base64EncodedString(), width: bitmap.width, height: bitmap.height))
    }

    static func jsonProperties(_ value: Any) -> Any {
        if let fields = value as? [String: Any] { return fields.compactMapValues { item in
            item is Data ? nil : jsonProperties(item)
        } }
        if let values = value as? [Any] { return values.filter { !($0 is Data) }.map(jsonProperties) }
        if value is String || value is NSNumber { return value }
        return NSNull()
    }

    static func strictPayload<T: Codable>(_ value: JSONValue, as type: T.Type) throws -> T {
        let decoded = try value.decoded(type)
        guard try JSONValue.from(decoded) == value else {
            throw WorkerFailure(code: "invalidRequest", message: "請求缺少必要欄位或包含未知欄位")
        }
        return decoded
    }

    // Go 傳入完整的 schema 12 配方；引擎在跨程序邊界仍驗證欄位及安全範圍。
    static func decodeRecipe(_ recipe: Recipe) throws -> (PhotoStyle, StyleAdjustment) {
        guard recipe.version == 1, let style = PhotoStyle(rawValue: recipe.style),
              case .object(let fields) = recipe.adjustment, fields["schemaVersion"] == .number(12) else {
            throw WorkerFailure(code: "invalidRecipe", message: "引擎只接受已正規化的 schema 12 配方")
        }
        let wrapped = JSONValue.object([style.rawValue: recipe.adjustment])
        guard let adjustment = try wrapped.decoded([String: StyleAdjustment].self)[style.rawValue],
              adjustment == adjustment.clamped(), try JSONValue.from(adjustment) == recipe.adjustment else {
            throw WorkerFailure(code: "invalidRecipe", message: "配方缺少欄位、包含未知值或尚未正規化")
        }
        return (style, adjustment)
    }

    static func render(_ job: RenderJob, id: String, useCache: Bool = false) throws -> JSONValue {
        let started = ProcessInfo.processInfo.systemUptime
        let (style, storedAdjustment) = try decodeRecipe(job.recipe)
        var adjustment = storedAdjustment
        if let policy = job.policy {
            adjustment.filmEffects.highlightProtectionEnabled = policy.highlightProtection
            adjustment.filmEffects.modernFilmExposureEnabled = policy.modernExposure
            if !policy.hdr { adjustment.hdrAmount = 0 }
        }
        guard let raw = PhotoRAWBackend(rawValue: job.input.rawDecoder),
              let compute = PhotoComputeBackend(rawValue: job.computeBackend),
              let format = PhotoExportFormat(rawValue: job.output.format),
              let colorSpace = PhotoExportColorSpace(rawValue: job.output.colorSpace),
              format.supportedBitDepths.contains(job.output.bitDepth),
              job.output.quality.isFinite, (0...1).contains(job.output.quality),
              job.output.maxPixel >= 0, job.output.maxPixel <= 65536,
              (1...8192).contains(job.previewMaxPixel), [1, 5].contains(job.output.tiffCompression) else {
            throw WorkerFailure(code: "invalidRequest", message: "解析、運算或匯出設定不符")
        }
        let inputURL = URL(fileURLWithPath: job.input.path).standardizedFileURL.resolvingSymlinksInPath()
        let outputURL = URL(fileURLWithPath: job.output.path).standardizedFileURL.resolvingSymlinksInPath()
        guard inputURL.path != outputURL.path, !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw WorkerFailure(code: "outputExists", message: "引擎只接受尚不存在的工作暫存成品")
        }
        let patches = try job.recipe.repairPatches.decoded([PhotoRepairPatch].self)
        guard patches.allSatisfy({ patch in
            [patch.x, patch.y, patch.width, patch.height, patch.linearGain].allSatisfy(\.isFinite)
                && patch.width > 0 && patch.height > 0 && patch.linearGain > 0
                && CIImage(data: patch.imageData) != nil && CIImage(data: patch.maskData) != nil
        }) else { throw WorkerFailure(code: "invalidRepair", message: "修復紀錄不完整或影像無法解碼") }
        let decodePurpose: PhotoRAWDecodePurpose = job.preview && job.policy?.fullResolution != true ? .preview
            : (job.preview && job.recipe.detectSubject && job.subjectMask == nil ? .completeWithPreview : .complete)
        let bytes = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        let key = useCache ? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            + ":" + raw.rawValue + ":" + String(job.input.lensCorrection) + ":" + inputURL.pathExtension.lowercased() : ""
        let sourceCacheHit = useCache && previewCache.key == key && previewCache.source != nil
            && (previewCache.source?.rawDecoderBackend != .software || previewCache.sourcePurpose == decodePurpose)
        let cache: PreviewCache
        if useCache {
            if !sourceCacheHit { previewCache = PreviewCache(); previewCache.key = key }
            cache = previewCache
        } else { cache = PreviewCache() }
        if cache.source == nil {
            let decoded = try decodeSource(job.input, data: bytes, url: inputURL, purpose: decodePurpose)
            cache.source = decoded
            cache.sourcePurpose = decodePurpose
        }
        var image = cache.source!
        let sourceSize = image.decodedSourceSize ?? image.size
        var processingCacheHit = false
        if job.preview && job.policy?.fullResolution != true {
            if let index = cache.processing.firstIndex(where: { $0.size == job.previewMaxPixel }) {
                let entry = cache.processing.remove(at: index)
                cache.processing.append(entry)
                image = entry.image
                processingCacheHit = true
            } else {
                image = image.processingPreview(maxPixel: CGFloat(job.previewMaxPixel))
                cache.processing.append((size: job.previewMaxPixel, image: image))
                if cache.processing.count > 2 { cache.processing.removeFirst() }
            }
        }
        let decodedAt = ProcessInfo.processInfo.systemUptime
        var subjectMask: CIImage?
        var maskCacheHit = false
        if job.recipe.detectSubject && (job.preview || job.subjectMask != nil) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let repairData = try encoder.encode(job.recipe.repairPatches)
            let maskKey = SHA256.hash(data: repairData).map { String(format: "%02x", $0) }.joined() + (job.subjectMask?.sha256 ?? "")
            maskCacheHit = cache.maskKey == maskKey
            if !maskCacheHit {
                // 與原 Swift UI 相同，以編輯縮圖偵測一次，重用於成品及裁切預覽。
                if let saved = job.subjectMask { cache.mask = try savedSubjectMask(saved) }
                else { cache.mask = PhotoStyleProcessor.detectSubjectMask(for:
                    PhotoStyleProcessor.repairedSource(cache.source!.editingWebPreview(), patches: patches)) }
                cache.maskKey = maskKey
            }
            subjectMask = cache.mask
        }
        let stageEncoder = JSONEncoder()
        stageEncoder.outputFormatting = [.sortedKeys]
        let stageScope = try stageEncoder.encode(EditorCacheKey(style: job.recipe.style,
            adjustment: StyleAdjustment.default(for: .original), repairs: job.recipe.repairPatches,
            maskKey: job.recipe.detectSubject ? cache.maskKey : nil, detectSubject: job.recipe.detectSubject,
            computeBackend: job.computeBackend, policy: job.policy, maxPixel: job.previewMaxPixel))
        let stageScopeKey = SHA256.hash(data: stageScope).map { String(format: "%02x", $0) }.joined()
        let stageCache = useCache && job.preview ? cache.stages : nil
        let previousStageHits = cache.stages.hits
        let completion = Completion()
        let rendered = try PhotoStyleProcessor.render(style: style, adjustment: adjustment, to: image,
            subjectMask: subjectMask, shouldDetectSubjectMask: !job.preview && job.recipe.detectSubject, repairPatches: patches, isPreview: job.preview,
            progress: { value in
                completion.update(value)
                try? emit(Response(version: 1, id: id, kind: "progress", payload: .number(value), error: nil))
            }, compute: PhotoBackendRouter.compute(compute), cache: stageCache, cacheScope: stageScopeKey)
        if job.preview, job.subjectMask == nil, let path = job.subjectMaskOutputPath, let mask = subjectMask {
            let width = Int(mask.extent.width), height = Int(mask.extent.height)
            guard mask.extent.origin == .zero, width > 0, height > 0, width <= 4096, height <= 4096 else { throw WorkerFailure(code:"invalidMask",message:"主體遮罩尺寸不符") }
            var data = Data("FYPMASK1".utf8)
            for value in [UInt32(width).littleEndian, UInt32(height).littleEndian] { withUnsafeBytes(of:value) { data.append(contentsOf:$0) } }
            data.append(Data(count:width*height*16))
            data.withUnsafeMutableBytes { bytes in
                CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!]).render(mask,toBitmap:bytes.baseAddress!.advanced(by:16),rowBytes:width*16,bounds:mask.extent,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            }
            try data.write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)
        }
        let renderedAt = ProcessInfo.processInfo.systemUptime
        guard completion.finished, let resized = rendered.resizedForExport(maxPixel: job.output.maxPixel),
              let output = resized.encodedData(format: format, bitDepth: job.output.bitDepth,
                quality: job.output.quality, webPLossless: job.output.webPLossless,
                tiffCompression: job.output.tiffCompression, exportColorSpace: colorSpace) else {
            throw WorkerFailure(code: "renderFailed", message: "完整渲染或成品編碼未完成")
        }
        try output.write(to: outputURL, options: .withoutOverwriting)
        var previewFields: [String: Any] = [:]
        if job.preview {
            let editing = adjustment.forSourceEditingPreview
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let editorSettings = EditorCacheKey(style: job.recipe.style, adjustment: editing,
                repairs: job.recipe.repairPatches, maskKey: job.recipe.detectSubject ? cache.maskKey : nil,
                detectSubject: job.recipe.detectSubject, computeBackend: job.computeBackend,
                policy: job.policy, maxPixel: job.previewMaxPixel)
            let editorKey = SHA256.hash(data: try encoder.encode(editorSettings)).map { String(format: "%02x", $0) }.joined()
            var editorCacheHit = false
            if editing != adjustment, let index = cache.editors.firstIndex(where: { $0.key == editorKey }) {
                let entry = cache.editors.remove(at: index)
                cache.editors.append(entry)
                previewFields["cropImage"] = entry.image
                editorCacheHit = true
            } else {
                let editor = editing == adjustment ? rendered : try PhotoStyleProcessor.render(style: style,
                    adjustment: editing, to: image, subjectMask: subjectMask, shouldDetectSubjectMask: false,
                    repairPatches: patches, isPreview: true, compute: PhotoBackendRouter.compute(compute),
                    cache: stageCache, cacheScope: stageScopeKey)
                let data: Data
                if editing == adjustment && format == .jpeg && job.output.quality == 0.88
                    && job.output.maxPixel == job.previewMaxPixel && colorSpace == .sRGB {
                    data = output
                } else {
                    guard let encoded = editor.resizedForWebPreview(maxPixel: CGFloat(job.previewMaxPixel)).jpegData(compressionQuality: 0.88) else {
                        throw WorkerFailure(code: "renderFailed", message: "無法產生來源編輯圖")
                    }
                    data = encoded
                }
                let editorPayload = "data:image/jpeg;base64," + data.base64EncodedString()
                previewFields["cropImage"] = editorPayload
                cache.editors.removeAll { $0.key == editorKey }
                // 只保存顯示用 JPEG，避免持有額外的原尺寸 Float32 影像。
                if editorPayload.utf8.count <= 16 * 1024 * 1024 {
                    cache.editors.append((key: editorKey, image: editorPayload))
                    while cache.editors.count > 2 || cache.editors.reduce(0, { $0 + $1.image.utf8.count }) > 16 * 1024 * 1024 {
                        cache.editors.removeFirst()
                    }
                }
            }
            let comparisonKey = "\(job.policy?.fullResolution == true):\(job.previewMaxPixel):"
                + "\(adjustment.cropAspectRatio):\(adjustment.cropRotation):\(adjustment.cropScale):"
                + "\(adjustment.cropWidth):\(adjustment.cropHeight):\(adjustment.cropHorizontalPosition):\(adjustment.cropVerticalPosition)"
            var comparisonCacheHit = false
            let comparison: String
            if let index = cache.comparisons.firstIndex(where: { $0.key == comparisonKey }) {
                let entry = cache.comparisons.remove(at: index)
                cache.comparisons.append(entry)
                comparison = entry.image
                comparisonCacheHit = true
            } else {
                let rotated = image.originalRendering.rotatedForCrop(degrees: adjustment.cropRotation)
                let rect = adjustment.cropRect(in: CGRect(origin: .zero, size: rotated.size))
                let cropped = rect == CGRect(origin: .zero, size: rotated.size) ? rotated : rotated.cropped(to: rect)
                guard let data = cropped.resizedForWebPreview(maxPixel: CGFloat(job.previewMaxPixel)).jpegData(compressionQuality: 0.88) else {
                    throw WorkerFailure(code: "renderFailed", message: "無法產生原圖比較")
                }
                comparison = "data:image/jpeg;base64," + data.base64EncodedString()
                cache.comparisons.append((key: comparisonKey, image: comparison))
                if cache.comparisons.count > 2 { cache.comparisons.removeFirst() }
            }
            previewFields["sourceImage"] = comparison
            previewFields["timing"] = ["decodeMilliseconds": (decodedAt - started) * 1000,
                "renderMilliseconds": (renderedAt - decodedAt) * 1000,
                "encodeMilliseconds": (ProcessInfo.processInfo.systemUptime - renderedAt) * 1000,
                "sourceCacheHit": sourceCacheHit, "processingCacheHit": processingCacheHit,
                "maskCacheHit": maskCacheHit, "comparisonCacheHit": comparisonCacheHit,
                "editorCacheHit": editorCacheHit, "stageCacheHits": cache.stages.hits - previousStageHits] as [String: Any]
        }
        let cropSize = adjustment.cropRect(in: CGRect(origin: .zero, size: sourceSize)).size
        let outputSize = PhotoStyleProcessor.renderedOutputSize(for: sourceSize, adjustment: adjustment)
        previewFields["cropWidth"] = Int(cropSize.width); previewFields["cropHeight"] = Int(cropSize.height)
        previewFields["outputWidth"] = Int(outputSize.width); previewFields["outputHeight"] = Int(outputSize.height)
        return try payload(previewFields.merging(["width": Int(resized.size.width), "height": Int(resized.size.height),
                            "sourceWidth": Int(sourceSize.width), "sourceHeight": Int(sourceSize.height),
                            "bytes": output.count, "computeBackend": compute.rawValue,
                            "rawDecoder": cache.source?.rawDecoderBackend?.rawValue ?? "not-raw",
                            "softwareRAWFallback": cache.source?.softwareRAWFallback ?? false,
                            "systemRAWFallback": raw == .system && cache.source?.rawDecoderBackend == .software,
                            "embeddedRAWPreview": cache.source?.usesEmbeddedRAWPreview ?? false]) { a, _ in a })
    }
}
