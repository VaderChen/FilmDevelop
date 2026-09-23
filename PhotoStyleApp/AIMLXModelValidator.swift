import Foundation
import CoreFoundation

/// Offline validation for the VLM families registered by Tanpopo's MLXVLM runtime.
/// Only JSON metadata and safetensors headers are read; tensor payloads stay on disk.
enum AIMLXModelValidator {
    struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let processorsByModel: [String: String] = [
        "paligemma": "PaliGemmaProcessor", "qwen2_vl": "Qwen2VLProcessor",
        "qwen2_5_vl": "Qwen2_5_VLProcessor", "qwen3_vl": "Qwen3VLProcessor",
        "qwen3_5": "Qwen3VLProcessor", "qwen3_5_moe": "Qwen3VLProcessor",
        "idefics3": "Idefics3Processor", "gemma3": "Gemma3Processor",
        "gemma4": "Gemma4Processor", "gemma4_unified": "Gemma4UnifiedProcessor",
        "smolvlm": "SmolVLMProcessor", "fastvlm": "FastVLMProcessor",
        "llava_qwen2": "FastVLMProcessor", "pixtral": "PixtralProcessor",
        "mistral3": "Mistral3Processor", "lfm2_vl": "Lfm2VlProcessor",
        "lfm2-vl": "Lfm2VlProcessor", "glm_ocr": "Glm46VProcessor"
    ]

    static func supports(modelType: String) -> Bool { processorsByModel[modelType] != nil }

    static func isCandidate(at directory: URL) -> Bool {
        guard let root = try? modelRoot(directory),
              let config = try? json(named: "config.json", root: root),
              let type = config["model_type"] as? String,
              processorsByModel[type] != nil,
              let vision = config["vision_config"] as? [String: Any], !vision.isEmpty,
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else { return false }
        return children.contains { $0.pathExtension == "safetensors" || $0.lastPathComponent == "model.safetensors.index.json" }
    }

    static func validate(at directory: URL) throws {
        do {
            try validateModel(at: directory)
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError(message: "無法讀取 MLX 模型：\(error.localizedDescription)")
        }
    }

    private static func validateModel(at directory: URL) throws {
        let root = try modelRoot(directory)
        let config = try json(named: "config.json", root: root)
        guard let type = config["model_type"] as? String,
              let expectedProcessor = processorsByModel[type] else {
            throw failure("此模型不是目前支援的 MLX 視覺語言模型。")
        }
        guard let vision = config["vision_config"] as? [String: Any], !vision.isEmpty else {
            throw failure("模型缺少 vision_config，純文字模型無法分析照片。")
        }

        // Match MLXVLM's preference and its two processor-type overrides.
        let processorName = FileManager.default.fileExists(atPath: root.appendingPathComponent("preprocessor_config.json").path)
            ? "preprocessor_config.json" : "processor_config.json"
        let processor = try json(named: processorName, root: root)
        guard let processorClass = processor["processor_class"] as? String, !processorClass.isEmpty else {
            throw failure("\(processorName) 缺少影像處理器設定。")
        }
        let resolvedProcessor = ["mistral3", "gemma4_unified"].contains(type) ? expectedProcessor : processorClass
        guard resolvedProcessor == expectedProcessor else {
            throw failure("影像處理器 \(processorClass) 與 \(type) 模型不相容。")
        }
        let tokenizerConfiguration = try json(named: "tokenizer_config.json", root: root)
        guard !tokenizerConfiguration.isEmpty else { throw failure("tokenizer_config.json 是空的。") }
        let tokenizer = try json(named: "tokenizer.json", root: root, maximumBytes: 128 * 1024 * 1024)
        guard let tokenizerModel = tokenizer["model"] as? [String: Any],
              let tokenizerType = tokenizerModel["type"] as? String, !tokenizerType.isEmpty,
              ((tokenizerModel["vocab"] as? [String: Any])?.isEmpty == false
               || (tokenizerModel["vocab"] as? [Any])?.isEmpty == false) else {
            throw failure("tokenizer.json 缺少有效的分詞器或詞彙表。")
        }

        let files = try weightFiles(in: root)
        guard !files.isEmpty else { throw failure("找不到 MLX safetensors 權重檔。") }
        let indexURL = root.appendingPathComponent("model.safetensors.index.json")
        var weightMap: [String: String]?
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let index = try json(named: indexURL.lastPathComponent, root: root, maximumBytes: 32 * 1024 * 1024)
            guard let map = index["weight_map"] as? [String: String], !map.isEmpty else {
                throw failure("模型分片索引缺少有效的 weight_map。")
            }
            let expectedFiles = try Set(map.values.map { name -> String in
                guard name.hasSuffix(".safetensors") else { throw failure("索引包含非 safetensors 權重：\(name)") }
                _ = try checkedFile(named: name, root: root)
                return name
            })
            guard expectedFiles == Set(files.keys) else {
                throw failure("MLX 權重分片與索引不一致，請確認所有分片已完整下載，且未混入其他模型。")
            }
            weightMap = map
        } else if files.count > 1 {
            throw failure("分片模型缺少 model.safetensors.index.json，無法確認下載完整性。")
        }

        var tensorNames = Set<String>()
        for (name, file) in files.sorted(by: { $0.key < $1.key }) {
            let names = try validateSafetensors(file)
            guard tensorNames.isDisjoint(with: names) else { throw failure("模型分片含有重複權重。") }
            if let map = weightMap, !names.allSatisfy({ map[$0] == name }) {
                throw failure("\(name) 的權重內容與分片索引不符。")
            }
            tensorNames.formUnion(names)
        }
        if let map = weightMap, tensorNames != Set(map.keys) {
            throw failure("分片索引列出的部分權重不存在，模型下載不完整。")
        }
        guard tensorNames.contains(where: { name in
            name.split(separator: ".").contains { $0 == "visual" || $0.hasPrefix("vision") }
        }) else {
            throw failure("模型沒有視覺編碼器權重，無法分析照片。")
        }
    }

    private static func modelRoot(_ directory: URL) throws -> URL {
        guard directory.isFileURL else { throw failure("請選擇本機 MLX 模型目錄。") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw failure("MLX 模型路徑不是目錄。")
        }
        return root
    }

    private static func checkedFile(named name: String, root: URL) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw failure("模型包含不合法的檔案路徑：\(name)")
        }
        let file = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            throw failure("模型檔案的符號連結超出所選目錄：\(name)")
        }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw failure("模型缺少必要檔案：\(name)")
        }
        return file
    }

    private static func json(named name: String, root: URL, maximumBytes: Int = 4 * 1024 * 1024) throws -> [String: Any] {
        let file = try checkedFile(named: name, root: root)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.seekToEnd() <= maximumBytes else { throw failure("\(name) 超過合理的設定檔大小。") }
        try handle.seek(toOffset: 0)
        guard let data = try handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("\(name) 不是有效的 JSON 設定檔，可能尚未下載完成。")
        }
        return value
    }

    private static func weightFiles(in root: URL) throws -> [String: URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw failure("無法讀取 MLX 模型目錄。")
        }
        var files: [String: URL] = [:]
        var count = 0
        for case let enumeratedFile as URL in enumerator {
            // Foundation's enumerator can expand /var to /private/var even when
            // its root URL is normalized. Normalize both before taking a relative path.
            let file = enumeratedFile.standardizedFileURL
            guard file.path.hasPrefix(root.path + "/") else { throw failure("權重檔超出所選模型目錄。") }
            count += 1
            guard count <= 10_000 else { throw failure("模型目錄包含過多檔案，請直接選擇單一模型目錄。") }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                    throw failure("模型含有超出所選目錄的符號連結：\(file.lastPathComponent)")
                }
            }
            guard file.pathExtension == "safetensors" else { continue }
            let name = String(file.path.dropFirst(root.path.count + 1))
            files[name] = try checkedFile(named: name, root: root)
        }
        if let error = enumerationError { throw error }
        return files
    }

    private static func validateSafetensors(_ file: URL) throws -> Set<String> {
        let name = file.lastPathComponent
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw failure("\(name) 權重檔頭不完整。")
        }
        let headerSize = prefix.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        guard headerSize >= 2, headerSize <= 32 * 1024 * 1024, fileSize >= 8 + headerSize,
              let header = try handle.read(upToCount: Int(headerSize)), header.count == Int(headerSize),
              let tensors = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            throw failure("\(name) 不是有效的 safetensors 權重，或下載尚未完成。")
        }
        let payloadSize = fileSize - 8 - headerSize
        let bytesByType: [String: UInt64] = ["BOOL": 1, "I8": 1, "U8": 1, "I16": 2, "U16": 2,
            "I32": 4, "U32": 4, "I64": 8, "U64": 8, "F16": 2, "BF16": 2, "F32": 4, "F64": 8,
            "F8_E4M3": 1, "F8_E5M2": 1, "F8_E4M3FN": 1, "F8_E4M3FNUZ": 1, "F8_E5M2FNUZ": 1]
        var ranges: [(UInt64, UInt64)] = []
        var names = Set<String>()
        for (tensorName, value) in tensors where tensorName != "__metadata__" {
            guard !tensorName.isEmpty, let tensor = value as? [String: Any],
                  let dtype = tensor["dtype"] as? String, let width = bytesByType[dtype],
                  let shape = tensor["shape"] as? [Any],
                  let offsets = tensor["data_offsets"] as? [Any], offsets.count == 2,
                  let start = unsigned(offsets[0]), let end = unsigned(offsets[1]),
                  start <= end, end <= payloadSize else { throw failure("\(name) 的權重欄位或資料範圍不完整。") }
            var byteCount = width
            for dimension in shape {
                guard let size = unsigned(dimension) else { throw failure("\(name) 的權重維度無效。") }
                let product = byteCount.multipliedReportingOverflow(by: size)
                guard !product.overflow else { throw failure("\(name) 的權重維度過大。") }
                byteCount = product.partialValue
            }
            guard end - start == byteCount else { throw failure("\(name) 的權重大小與維度不符。") }
            names.insert(tensorName)
            ranges.append((start, end))
        }
        guard !names.isEmpty else { throw failure("\(name) 沒有任何權重資料。") }
        var cursor: UInt64 = 0
        for (start, end) in ranges.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
            guard start == cursor else { throw failure("\(name) 的權重資料重疊或缺漏。") }
            cursor = end
        }
        guard cursor == payloadSize else { throw failure("\(name) 的權重檔案大小不符，請重新下載。") }
        return names
    }

    private static func unsigned(_ value: Any) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    private static func failure(_ message: String) -> ValidationError { ValidationError(message: message) }
}
