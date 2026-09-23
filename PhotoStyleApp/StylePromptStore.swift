import Foundation

final class StylePromptStore {
    private let defaults: UserDefaults
    private let defaultsKey = "stylePrompts.v1"
    private static let supportedLanguages = ["traditionalChinese", "english", "japanese", "korean"]
    private var prompts: [String: [String: String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            prompts = decoded
        } else if let data = defaults.data(forKey: defaultsKey),
                  let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            prompts = Dictionary(uniqueKeysWithValues: legacy.map { styleID, prompt in
                (styleID, ["english": prompt])
            })
        } else {
            prompts = [:]
        }
    }

    func prompt(for style: PhotoStyle, language: String) -> String {
        let language = Self.normalizedLanguage(language)
        return customPrompt(for: style, language: language) ?? style.llmDescription(for: language)
    }

    func prompts(for style: PhotoStyle) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.supportedLanguages.map { language in
            (language, prompt(for: style, language: language))
        })
    }

    func customPrompt(for style: PhotoStyle, language: String) -> String? {
        let language = Self.normalizedLanguage(language)
        guard let prompt = prompts[style.rawValue]?[language]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty,
              prompt != style.llmDescription(for: language) else {
            return nil
        }
        return prompt
    }

    func customizedLanguages(for style: PhotoStyle) -> [String] {
        guard let stylePrompts = prompts[style.rawValue] else { return [] }
        return Self.supportedLanguages.filter { language in
            guard let prompt = stylePrompts[language]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !prompt.isEmpty && prompt != style.llmDescription(for: language)
        }
    }

    func setPrompt(_ prompt: String, for style: PhotoStyle, language: String) {
        let language = Self.normalizedLanguage(language)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == style.llmDescription(for: language) {
            prompts[style.rawValue]?[language] = nil
        } else {
            var stylePrompts = prompts[style.rawValue] ?? [:]
            stylePrompts[language] = trimmed
            prompts[style.rawValue] = stylePrompts
        }
        if prompts[style.rawValue]?.isEmpty == true {
            prompts.removeValue(forKey: style.rawValue)
        }
        persist()
    }

    func resetPrompt(for style: PhotoStyle, language: String) {
        let language = Self.normalizedLanguage(language)
        prompts[style.rawValue]?[language] = nil
        if prompts[style.rawValue]?.isEmpty == true {
            prompts.removeValue(forKey: style.rawValue)
        }
        persist()
    }

    static func normalizedLanguage(_ language: String?) -> String {
        guard let language else { return "traditionalChinese" }
        switch language {
        case "traditionalChinese", "english", "japanese", "korean":
            return language
        default:
            return "traditionalChinese"
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
