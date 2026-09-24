import PhotoStyleShared
import Foundation

enum PhotoStyleMCPTools {
    static let numericRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [:]
        for key in ["intensity", "brightness", "grain", "vignette", "denoise", "devignette", "backgroundBlur", "skinWhitening", "skinSmoothing", "hdrAmount"] { ranges[key] = 0...100 }
        for key in ["skinWarmth", "exposure", "whiteBalanceWarmth", "whiteBalanceTint", "contrast", "vignetteBalance", "cropHorizontalPosition", "cropVerticalPosition"] { ranges[key] = -100...100 }
        ranges["cropRotation"] = -45...45
        for key in ["cropScale", "cropWidth", "cropHeight"] { ranges[key] = 20...100 }
        for region in ["highlight", "midtone", "shadow"] {
            for field in ["Exposure", "Warmth", "PlanBaseTone", "PlanContrast", "PlanTint", "PlanHighlights", "PlanShadows"] { ranges[region + field] = -100...100 }
            for field in ["Intensity", "Grain", "PlanFade", "PlanSoftness"] { ranges[region + field] = 0...100 }
        }
        for key in ["grainClumping", "grainChroma", "bloomAmount", "bloomThreshold", "halationAmount", "halationThreshold", "monochromeFilterStrength", "printContrast", "developmentAmount", "developmentTime", "developmentAgitation"] { ranges[key] = 0...100 }
        ranges["printExposure"] = PhotoFilmEffects.printExposureRange
        ranges["developmentDiffusion"] = 0.02...1
        ranges["grainSize"] = 0.5...4
        ranges["bloomRadius"] = 0.05...2
        ranges["halationRadius"] = 0.01...0.3
        ranges["scanSaturation"] = 0...100
        ranges["scanDensityCorrection"] = 0...100
        ranges["scanFlare"] = 0...100
        ranges["scanMidtoneWarmth"] = -100...100
        ranges["scanHighlightWarmth"] = -100...100
        return ranges
    }()
    static let stringValues: [String: [String]] = [
        "cropAspectRatio": CropAspectRatio.allCases.map(\.rawValue),
        "frameStyle": FrameStyle.allCases.map(\.rawValue),
        "dateStyle": DateStampStyle.allCases.map(\.rawValue),
        "grainMode": PhotoFilmEffects.GrainMode.allCases.map(\.rawValue),
        "printIlluminant": PhotoFilmEffects.Illuminant.allCases.map(\.rawValue),
        "viewIlluminant": PhotoFilmEffects.Illuminant.allCases.map(\.rawValue),
        "scannerProfile": PhotoFilmEffects.ScannerProfile.allCases.map(\.rawValue),
        "scannerIlluminant": PhotoFilmEffects.Illuminant.allCases.map(\.rawValue),
        "filmColorModel": PhotoFilmEffects.ColorModel.allCases.map(\.rawValue),
        "monochromeFilter": ["none", "yellow", "orange", "red", "green"]
    ]
    static let booleanKeys = ["frameEnabled", "dateEnabled"]
    static let adjustmentProperties: [String: Any] = {
        var values: [String: Any] = [:]
        for (key, range) in numericRanges { values[key] = ["type": "number", "minimum": range.lowerBound, "maximum": range.upperBound] }
        for (key, options) in stringValues { values[key] = ["type": "string", "enum": options] }
        let illuminants = PhotoFilmEffects.Illuminant.allCases.map { "\($0.rawValue) \($0.title)" }.joined(separator: "、")
        let descriptions = [
            "scannerProfile": "off 關閉掃描；neutral 中性掃描（預設）；warmCool 暖中調冷亮部的掃描。底片與原片皆可使用；原片僅套用掃描色彩調整。非實測商用掃描器。",
            "scannerIlluminant": "底掃穿透光源，片基自動平衡；與印相、觀看光源分開。",
            "scanSaturation": "底掃色彩濃度，50 為中性，0 灰階；黑白底片維持灰階。",
            "scanDensityCorrection": "負片密度域色層去耦合程度，100 完整校正；正片與黑白略過。",
            "scanFlare": "掃描器雜散光，0 關閉，100 相當於片基參考透射訊號的 0.5%。",
            "scanMidtoneWarmth": "底掃中調冷暖，正暖負冷，0 保留所選底掃風格。",
            "scanHighlightWarmth": "底掃亮部冷暖，正暖負冷，純白附近減弱染色。",
            "filmColorModel": "固定 spectral：LHTSS 光譜重建、多波段染料透射與獨立印片流程；只對底片款式生效。",
            "printExposure": "風格與底片皆可調整的印相／觀看曝光補償 EV，-4 至 +4，預設 0；正值變亮、負值變暗。",
            "printIlluminant": "印相光源：\(illuminants)。一般風格與負片皆可使用，正片略過此光源。",
            "viewIlluminant": "觀看光源：\(illuminants)。風格與底片皆可使用，黑白維持灰階。",
            "printContrast": "風格與底片皆可調整的印相反差，50 保留原有基準；反轉片調整觀看密度反差。",
            "developmentAmount": "顯影擴散效果量，0 關閉；模擬共享顯影液耗竭與補充。",
            "developmentTime": "相對顯影時間，50 為基準，越大耗竭與鄰接作用越明顯。",
            "developmentDiffusion": "顯影液擴散尺度，以完整影像長邊百分比表示。",
            "developmentAgitation": "顯影液攪拌／補充程度；越高越能補充局部耗竭。",
            "grainMode": "統一使用 emulsion：顯影前 Poisson 晶體捕光與分層返照。顆粒量沿用 grain 與各分區 Grain。",
            "grainSize": "顆粒尺寸：原圖長邊 3000 像素時的像素大小；預覽與匯出依原圖比例換算。",
            "grainClumping": "乳劑晶體的聚集程度，調整局部 Poisson 粒子密度變化。",
            "grainChroma": "乳劑顆粒的彩色比例；黑白風格會維持灰階。",
            "bloomAmount": "高光中性散射柔光強度；0 關閉，與紅暈分別調整，隨整體風格強度縮放。",
            "bloomRadius": "柔光範圍，以未裁切原圖長邊百分比表示。",
            "bloomThreshold": "觸發柔光的線性亮度門檻百分比。",
            "halationAmount": "高光紅橙返照強度；黑白風格呈灰階光暈；0 關閉，隨整體風格強度縮放。",
            "halationRadius": "紅暈範圍，以未裁切原圖長邊百分比表示。",
            "halationThreshold": "觸發紅暈的線性亮度門檻百分比。",
            "monochromeFilter": "黑白感光色濾鏡，只在黑白風格生效；none 為關閉。",
            "monochromeFilterStrength": "黑白感光色濾鏡濃度；0 為自然灰階混色。"
        ]
        for (key, description) in descriptions {
            var property = values[key] as! [String: Any]
            property["description"] = description
            values[key] = property
        }
        for key in booleanKeys { values[key] = ["type": "boolean"] }
        return values
    }()

    static let definitions: [[String: Any]] = [
        tool("get_state", "讀取目前照片、風格、調整參數與處理進度。", readOnly: true),
        tool("list_styles", "列出可套用的照片風格與底片模型，包括底片分類與演算法描述。", readOnly: true),
        tool("get_preview", "取得目前處理結果的 JPEG 預覽影像。", readOnly: true),
        tool("open_image", "開啟本機照片並同步更新 App 的預覽、檔名與參數。", properties: ["path": ["type": "string", "description": "照片的絕對檔案路徑"]], required: ["path"]),
        tool("set_style", "選取風格並同步更新 App。", properties: ["style": ["type": "string", "enum": PhotoStyle.allCases.map(\.rawValue)]], required: ["style"]),
        tool("update_adjustments", "更新目前風格的參數並同步預覽與滑桿。所有參數會先驗證再套用。", properties: ["changes": ["type": "object", "properties": adjustmentProperties, "additionalProperties": false, "minProperties": 1]], required: ["changes"]),
        tool("import_color_calibration", "匯入量測色彩校準 JSON 並同步預覽；不由 AI 臆造係數。", properties: ["path": ["type": "string"]], required: ["path"]),
        tool("clear_color_calibration", "移除目前照片／風格的色彩校準並同步預覽。"),
        tool("run_ai", "啟動已安裝的本機 AI 分析；可提供僅限本次的 prompt 或語言，不會修改已儲存 Prompt。使用 get_state 查詢完成狀態。", properties: [
            "prompt": ["type": "string", "minLength": 1, "maxLength": 8000,
                       "description": "僅限本次的指令；去除前後空白後須為 1 至 8000 字元。省略時使用目前風格在指定語言的已儲存 Prompt。"],
            "language": ["type": "string", "enum": ["traditionalChinese", "english", "japanese", "korean"],
                         "description": "選擇本次使用的已儲存 Prompt 語言；省略時使用 App 目前語言，不改變介面偏好。"]
        ]),
        tool("cancel_ai", "要求取消 AI 分析；使用 get_state 確認運算清理完成，已完成套用的結果不會回復。"),
        tool("export_image", "以原始解析度匯出目前照片。PNG/TIFF 支援 8 或 16 bit；JPEG/WebP 僅支援 8 bit。不會自動降低指定色深，預設拒絕覆寫。", properties: [
            "path": ["type": "string", "description": "輸出絕對路徑，副檔名需與格式一致"],
            "format": ["type": "string", "enum": PhotoExportFormat.allCases.map(\.rawValue),
                       "description": "省略時依副檔名推斷；無法推斷時採 PNG，仍會驗證副檔名。"],
            "bitDepth": ["type": "integer", "enum": [8, 16],
                         "description": "每色彩通道位元數。省略時 TIFF 為 16，其餘為 8；8-bit PNG 不含透明度；JPEG/WebP 的 16 會被拒絕。"],
            "overwrite": ["type": "boolean", "default": false]
        ], required: ["path"]),
        tool("show_page", "切換 App 的前端頁面。", properties: ["page": ["type": "string", "enum": ["home", "styles", "films", "ai", "settings"]]], required: ["page"])
    ]
    static var names: [String] { definitions.compactMap { $0["name"] as? String } }

    private static func tool(_ name: String, _ description: String, readOnly: Bool = false, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": name == "export_image", "openWorldHint": false]]
    }

    static func validate(_ name: String, arguments: [String: Any]) throws {
        guard let definition = definitions.first(where: { $0["name"] as? String == name }) else { throw failure("不支援的工具。") }
        let schema = definition["inputSchema"] as! [String: Any]
        let properties = schema["properties"] as! [String: Any]
        for key in arguments.keys where properties[key] == nil { throw failure("不支援的參數：\(key)") }
        for key in schema["required"] as! [String] where arguments[key] == nil { throw failure("缺少參數：\(key)") }
        for (key, value) in arguments {
            let property = properties[key] as! [String: Any]
            switch property["type"] as? String {
            case "string":
                guard let text = value as? String else { throw failure("\(key) 必須是字串。") }
                if let values = property["enum"] as? [String], !values.contains(text) { throw failure("\(key) 的值不受支援。") }
                if key == "prompt", text.contains("\0") {
                    throw failure("prompt 不可包含空字元（NUL）。")
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let minimum = property["minLength"] as? Int, trimmed.count < minimum {
                    throw failure("\(key) 不可為空白。")
                }
                if let maximum = property["maxLength"] as? Int, trimmed.count > maximum {
                    throw failure("\(key) 不可超過 \(maximum) 字元。")
                }
            case "boolean":
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { throw failure("\(key) 必須是布林值。") }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else {
                    throw failure("\(key) 必須是整數。")
                }
                if let values = property["enum"] as? [Int], !values.contains(where: { Double($0) == number.doubleValue }) {
                    throw failure("\(key) 的值不受支援。")
                }
            case "object":
                guard let changes = value as? [String: Any], !changes.isEmpty else { throw failure("changes 必須是非空物件。") }
                for (key, value) in changes {
                    if let range = numericRanges[key] {
                        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, range.contains(number.doubleValue) else { throw failure("\(key) 必須介於 \(range.lowerBound) 與 \(range.upperBound)。") }
                    } else if let values = stringValues[key] {
                        guard let text = value as? String, values.contains(text) else { throw failure("\(key) 的值不受支援。") }
                    } else if booleanKeys.contains(key) {
                        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { throw failure("\(key) 必須是布林值。") }
                    } else { throw failure("不支援的調整參數：\(key)") }
                }
            default: break
            }
        }
        if name == "export_image" { _ = try exportOptions(arguments: arguments) }
    }

    static func exportOptions(arguments: [String: Any]) throws -> (format: PhotoExportFormat, bitDepth: Int) {
        guard let path = arguments["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else {
            throw failure("請提供絕對檔案路徑。")
        }
        let fileExtension = URL(fileURLWithPath: path).standardizedFileURL.pathExtension.lowercased()
        let format: PhotoExportFormat
        if let requested = arguments["format"] {
            guard let name = requested as? String, let recognized = PhotoExportFormat(rawValue: name) else {
                throw failure("format 的值不受支援。")
            }
            format = recognized
        } else {
            format = PhotoExportFormat.allCases.first { $0.fileExtensions.contains(fileExtension) } ?? .png
        }
        guard format.fileExtensions.contains(fileExtension) else {
            throw failure("輸出副檔名與 format 不一致；\(format.displayName) 請使用 \(format.fileExtensions.map { "." + $0 }.joined(separator: "、"))。")
        }
        let bitDepth: Int
        if let requested = arguments["bitDepth"] {
            guard let number = requested as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 8 || number.doubleValue == 16 else {
                throw failure("bitDepth 必須是整數 8 或 16。")
            }
            bitDepth = number.intValue
        } else {
            bitDepth = format.defaultBitDepth
        }
        guard format.supportedBitDepths.contains(bitDepth) else {
            throw failure("\(format.displayName) 不支援 \(bitDepth) bit；若需 16 bit，請選擇 PNG 或 TIFF。")
        }
        return (format, bitDepth)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoStyleMCP", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func result(_ value: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value, "isError": false]
    }
}
