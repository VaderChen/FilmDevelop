import Foundation

/// Presentation-only localization. Canonical messages, identifiers and user content stay unchanged.
enum PhotoL10n {
    static let preferenceKey = "interfaceLanguage.v1"
    static var preference: String {
        UserDefaults.standard.string(forKey: preferenceKey)
            ?? UserDefaults.standard.string(forKey: "promptLanguage.v1") ?? "automatic"
    }
    static func resolve(_ preference: String) -> String {
        if ["english", "japanese", "korean", "traditionalChinese"].contains(preference) { return preference }
        let system = Locale.preferredLanguages.first?.lowercased() ?? "zh-hant"
        if system.hasPrefix("en") { return "english" }
        if system.hasPrefix("ja") { return "japanese" }
        if system.hasPrefix("ko") { return "korean" }
        return "traditionalChinese"
    }
    static var language: String { resolve(preference) }
    static let catalog: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "localization-data", withExtension: "js", subdirectory: "Web"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let start = source.firstIndex(of: "{"), let end = source.lastIndex(of: "}"),
              let data = String(source[start...end]).data(using: .utf8),
              let object = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return object
    }()
    private struct Template {
        let key: String
        let regex: NSRegularExpression
        let indices: [String]
        let specificity: Int
    }
    private static let placeholders = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    private static let templates: [Template] = catalog.keys.compactMap { key in
        let source = key as NSString
        let matches = placeholders.matches(in: key, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return nil }
        var pattern = "^", offset = 0, indices: [String] = [], specificity = 0
        for match in matches {
            let literal = source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            pattern += NSRegularExpression.escapedPattern(for: literal) + "([\\s\\S]*?)"
            specificity += literal.count
            indices.append(source.substring(with: match.range(at: 1)))
            offset = NSMaxRange(match.range)
        }
        let tail = source.substring(from: offset)
        pattern += NSRegularExpression.escapedPattern(for: tail) + "$"
        return Template(key: key, regex: try! NSRegularExpression(pattern: pattern), indices: indices, specificity: specificity + tail.count)
    }.sorted { $0.specificity > $1.specificity }

    // This argument names a built-in style, never a user-defined film.
    private static let nestedArguments: [String: String] = [
        "以「{0}」為基礎儲存的自訂參數。": "0",
        "無法啟動：{0}": "0",
        "照片調整暫時無法儲存：{0}": "0",
        "無法還原模型目錄，請確認磁碟已連接或重新選擇。{0}": "0",
        "無法還原模型目錄，請重新選擇。{0}": "0",
        "無法讀取圖片：{0}": "0",
        "匯出失敗：{0}": "0",
        "無法記住這張照片：{0}": "0",
        "無法載入 AI 核心：{0}。{1}": "1",
        "MLX 分析失敗，照片未變更。{0}": "0",
        "無法讀取 MLX 模型：{0}": "0",
        "無法讀取照片目錄：{0}": "0",
        "無法刪除檔案：{0}": "0"
    ]

    static func text(_ source: String, language requestedLanguage: String? = nil, depth: Int = 0) -> String {
        let language = requestedLanguage ?? self.language
        guard let index = ["english": 0, "japanese": 1, "korean": 2][language] else { return source }
        if let values = catalog[source], values.indices.contains(index) { return values[index] }
        let nsSource = source as NSString
        for template in templates {
            guard let match = template.regex.firstMatch(in: source, range: NSRange(location: 0, length: nsSource.length)),
                  let values = catalog[template.key], values.indices.contains(index) else { continue }
            let translated = values[index] as NSString
            var result = values[index]
            // Replace in reverse order once, so user text containing {0} remains literal.
            for placeholder in placeholders.matches(in: values[index], range: NSRange(location: 0, length: translated.length)).reversed() {
                let id = translated.substring(with: placeholder.range(at: 1))
                guard let capture = template.indices.firstIndex(of: id), let range = Range(placeholder.range, in: result) else { continue }
                let argument = nsSource.substring(with: match.range(at: capture + 1))
                result.replaceSubrange(range, with: depth < 4 && nestedArguments[template.key] == id
                    ? text(argument, language: language, depth: depth + 1) : argument)
            }
            return result
        }
        return source
    }
}
