import Foundation
import CoreFoundation

public enum PhotoStylePlanJSONDecodeError: LocalizedError {
    case invalidUTF8
    case invalidPlan(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Generated plan is not valid UTF-8."
        case .invalidPlan(let reason):
            return "Generated plan is not a valid PhotoStylePlan JSON: \(reason)"
        }
    }
}

public enum PhotoStylePlanJSONDecoder {
    public static func decode(from text: String) throws -> PhotoStylePlan {
        let candidates = jsonCandidates(from: text)
        // Try every unmodified candidate first, including the contents of a
        // markdown fence, before considering repairs to malformed JSON.
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let plan = try? JSONDecoder().decode(PhotoStylePlan.self, from: data) {
                return plan
            }
        }
        var lastError: Error?
        for candidate in candidates {
            let sanitized = sanitizeDirtyJSON(candidate)
            guard let data = sanitized.data(using: .utf8) else {
                lastError = PhotoStylePlanJSONDecodeError.invalidUTF8
                continue
            }

            do {
                return try JSONDecoder().decode(PhotoStylePlan.self, from: data)
            } catch {
                lastError = error
            }
        }

        throw PhotoStylePlanJSONDecodeError.invalidPlan(lastError?.localizedDescription ?? "No JSON object found.")
    }

    /// Decode a newly generated result without treating missing or malformed controls as defaults.
    /// The permissive `decode` entry point remains available for legacy and partial saved plans.
    /// Live inference uses the current schema by default. Version 1 is available
    /// only when explicitly requested while validating an archived generation.
    public static func decodeGeneratedPlan(
        from text: String,
        requiredSchemaVersion: Int = PhotoStylePlan.currentSchemaVersion
    ) throws -> PhotoStylePlan {
        guard (1...PhotoStylePlan.currentSchemaVersion).contains(requiredSchemaVersion) else {
            throw generatedPlanError("Unsupported required schema version.")
        }
        let candidates = generatedJSONCandidates(from: text)
        var results: [PhotoStylePlan] = []
        var lastError: Error?
        for candidate in candidates {
            do {
                let data = Data(candidate.utf8)
                let value = try JSONSerialization.jsonObject(with: data)
                guard let object = value as? [String: Any] else {
                    throw generatedPlanError("The result must be a JSON object.")
                }
                try validateGeneratedPlan(object, requiredSchemaVersion: requiredSchemaVersion)
                results.append(try JSONDecoder().decode(PhotoStylePlan.self, from: data))
            } catch {
                lastError = error
            }
        }
        guard results.count <= 1 else {
            throw generatedPlanError("Multiple complete parameter plans were returned; the intended result is ambiguous.")
        }
        guard let result = results.first else {
            throw generatedPlanError(lastError?.localizedDescription ?? "No complete parameter plan was returned.")
        }
        return result
    }

    private static func generatedPlanError(_ message: String) -> PhotoStylePlanJSONDecodeError {
        .invalidPlan(message)
    }

    private static func validateGeneratedPlan(_ object: [String: Any], requiredSchemaVersion: Int) throws {
        func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
            guard let value = value as? [String: Any] else {
                throw generatedPlanError("\(path) must be an object containing all required controls.")
            }
            return value
        }
        func number(_ object: [String: Any], _ key: String, path: String = "", range: ClosedRange<Double>) throws -> Double {
            let field = path.isEmpty ? key : "\(path).\(key)"
            let numeric: Double?
            if let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
                numeric = value.doubleValue
            } else if let value = object[key] as? String {
                numeric = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                numeric = nil
            }
            guard let numeric, numeric.isFinite, range.contains(numeric) else {
                throw generatedPlanError("\(field) must be a finite number within \(range.lowerBound)...\(range.upperBound).")
            }
            return numeric
        }
        let schemaVersion: Int
        if let value = object["schema_version"] {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  (1...PhotoStylePlan.currentSchemaVersion).contains(where: { Double($0) == value.doubleValue }) else {
                throw generatedPlanError("schema_version must be a supported numeric version (1...\(PhotoStylePlan.currentSchemaVersion)).")
            }
            schemaVersion = value.intValue
        } else {
            schemaVersion = 1
        }
        guard schemaVersion == requiredSchemaVersion else {
            throw generatedPlanError("schema_version must be \(requiredSchemaVersion); legacy defaults cannot substitute for missing generated controls.")
        }
        if schemaVersion >= 3 {
            let editor = try dictionary(object["editor_controls"], path: "editor_controls")
            let keys = Set(PhotoEditorControls.numericRanges.keys)
                .union(PhotoEditorControls.enumValues.keys).union(PhotoEditorControls.booleanKeys)
            guard Set(editor.keys) == keys else {
                throw generatedPlanError("editor_controls must contain every documented editor control, without unknown fields.")
            }
            for (key, range) in PhotoEditorControls.numericRanges {
                guard let value = editor[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, range.contains(value.doubleValue) else {
                    throw generatedPlanError("editor_controls.\(key) must be a JSON number within \(range).")
                }
            }
            for (key, allowed) in PhotoEditorControls.enumValues {
                guard let value = editor[key] as? String, allowed.contains(value) else {
                    throw generatedPlanError("editor_controls.\(key) must be one of \(allowed).")
                }
            }
            for key in PhotoEditorControls.booleanKeys {
                guard let value = editor[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw generatedPlanError("editor_controls.\(key) must be a JSON boolean.")
                }
            }
        }
        if schemaVersion >= 2 {
            let film = try dictionary(object["film_effects"], path: "film_effects")
            let ranges: [String: ClosedRange<Double>] = [
                "grain_size": 0.5...4, "grain_clumping": 0...100, "grain_chroma": 0...100,
                "bloom_amount": 0...100, "bloom_radius": 0.05...2, "bloom_threshold": 0...100,
                "halation_amount": 0...100, "halation_radius": 0.01...0.3, "halation_threshold": 0...100,
                "monochrome_filter_strength": 0...100
            ]
            let requiredKeys = Set(ranges.keys).union(["grain_mode", "monochrome_filter"])
            // Version 2 saved/generated plans retain their original twelve controls.
            // The new controls are optional for backwards compatibility, but strict
            // when supplied; the current AI grammar emits the complete extension.
            var extendedRanges: [String: ClosedRange<Double>] = [
                "print_exposure": PhotoFilmEffects.printExposureRange, "print_contrast": 0...100,
                "development_amount": 0...100, "development_time": 0...100,
                "development_diffusion": 0.02...1, "development_agitation": 0...100
            ]
            let previousKeys = requiredKeys.union(extendedRanges.keys).union(["color_model"])
            let lightingKeys: Set<String> = ["print_illuminant", "view_illuminant"]
            let scannerRanges: [String: ClosedRange<Double>] = [
                "scan_exposure": -4...4,
                "scan_contrast": 0...100,
                "scan_saturation": 0...100,
                "scan_density_correction": 0...100,
                "scan_flare": 0...100,
                "scan_midtone_warmth": -100...100,
                "scan_highlight_warmth": -100...100
            ]
            for (key, value) in scannerRanges { extendedRanges[key] = value }
            let scannerKeys = Set(scannerRanges.keys).union(["scanner_profile", "scanner_illuminant"])
            let oldKeys = previousKeys.union(lightingKeys)
            let materialRanges: [String: ClosedRange<Double>] = [
                "print_exposure_highlights": PhotoFilmEffects.printExposureRange,
                "print_exposure_midtones": PhotoFilmEffects.printExposureRange,
                "print_exposure_shadows": PhotoFilmEffects.printExposureRange,
                "layer_response": 0...100,
                "coupler_amount": 0...100,
                "coupler_radius": 0...1,
                "film_width_mm": 8...120,
                "grain_distribution": 0...100,
                "emulsion_mtf": 0...100,
                "paper_scatter": 0...100,
                "paper_white": 80...100,
                "paper_density_offset": -1...1,
                "reciprocity_amount": 0...100,
                "exposure_seconds": 0.0001...3600,
                "halation_base": 0...100,
                "silver_retention": -100...100,
                "developer_temperature": 10...40,
                "developer_activity": 20...200,
            ]
            for (key, range) in materialRanges { extendedRanges[key] = range }
            if let raw = film["scanner_source"] {
                guard let raw = raw as? String, PhotoFilmEffects.ScannerSource(rawValue: raw) != nil else { throw generatedPlanError("Invalid scanner_source.") }
            }
            if let raw = film["paper_profile"] {
                guard let raw = raw as? String, PhotoFilmEffects.PaperProfile(rawValue: raw) != nil else { throw generatedPlanError("Invalid paper_profile.") }
            }
            let allowedKeys = oldKeys.union(scannerKeys).union(materialRanges.keys).union(["paper_profile", "scanner_source"])
            let mandatoryKeys = schemaVersion >= 6 ? oldKeys.union(scannerKeys) : (schemaVersion >= 5 ? oldKeys : (schemaVersion >= 3 ? previousKeys : requiredKeys))
            for key in lightingKeys.union(["scanner_illuminant"]) where film[key] != nil {
                guard let raw = film[key] as? String, PhotoFilmEffects.Illuminant(rawValue: raw) != nil else {
                    throw generatedPlanError("film_effects.\(key) must be one of: \(PhotoFilmEffects.Illuminant.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
            }
            if let value = film["scanner_profile"] {
                guard let raw = value as? String, PhotoFilmEffects.ScannerProfile(rawValue: raw) != nil else {
                    throw generatedPlanError("film_effects.scanner_profile must be one of: \(PhotoFilmEffects.ScannerProfile.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
            }
            guard mandatoryKeys.isSubset(of: Set(film.keys)), Set(film.keys).isSubset(of: allowedKeys) else {
                throw generatedPlanError("film_effects must contain all controls required by this schema version and only documented extensions.")
            }
            for (key, range) in extendedRanges where film[key] != nil {
                guard let value = film[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, range.contains(value.doubleValue) else {
                    throw generatedPlanError("film_effects.\(key) must be a JSON number within \(range.lowerBound)...\(range.upperBound).")
                }
            }
            if let model = film["color_model"] {
                guard let model = model as? String, PhotoFilmEffects.ColorModel(rawValue: model) != nil,
                      schemaVersion < 5 || model == "spectral" else {
                    throw generatedPlanError(schemaVersion >= 5 ? "film_effects.color_model must be spectral." : "film_effects.color_model must be analytic or spectral.")
                }
            }
            for (key, range) in ranges {
                guard let value = film[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, range.contains(value.doubleValue) else {
                    throw generatedPlanError("film_effects.\(key) must be a JSON number within \(range.lowerBound)...\(range.upperBound).")
                }
            }
            guard let grain = film["grain_mode"] as? String, PhotoFilmEffects.GrainMode(rawValue: grain) != nil,
                  schemaVersion < 5 || grain == "emulsion" else {
                throw generatedPlanError(schemaVersion >= 5 ? "film_effects.grain_mode must be emulsion." : "film_effects.grain_mode must be legacy, structured, crystal or emulsion.")
            }
            guard let filter = film["monochrome_filter"] as? String, PhotoFilmEffects.MonochromeFilter(rawValue: filter) != nil else {
                throw generatedPlanError("film_effects.monochrome_filter must be none, yellow, orange, red or green.")
            }
        } else if object["film_effects"] != nil {
            throw generatedPlanError("film_effects requires schema_version 2.")
        }
        for key in ["scene_summary", "recommended_style", "edit_prompt", "negative_prompt"] {
            if let value = object[key], !(value is String) {
                throw generatedPlanError("\(key) must be a string when present.")
            }
        }
        guard let colorMode = object["color_mode"] as? String,
              ["color", "monochrome"].contains(colorMode) else {
            throw generatedPlanError("color_mode must be color or monochrome.")
        }
        for key in ["strength", "background_blur", "skin_whitening", "skin_smoothing"] {
            _ = try number(object, key, range: 0...100)
        }
        let zones = try dictionary(object["tone_zones"], path: "tone_zones")
        for zone in ["shadows", "midtones", "highlights"] {
            let path = "tone_zones.\(zone)"
            let controls = try dictionary(zones[zone], path: path)
            for key in ["base_tone", "exposure", "contrast", "highlights", "shadows", "warmth", "tint"] {
                _ = try number(controls, key, path: path, range: -100...100)
            }
            for key in ["softness", "grain", "fade", "mapping"] {
                _ = try number(controls, key, path: path, range: 0...100)
            }
        }
        let hdr = try dictionary(object["hdr_tone_curve"], path: "hdr_tone_curve")
        var preceding = -Double.infinity
        for key in ["black", "shadows", "midtones", "highlights", "white"] {
            let value = try number(hdr, key, path: "hdr_tone_curve", range: 0...100)
            guard value >= preceding else {
                throw generatedPlanError("hdr_tone_curve control points must be nondecreasing from black to white.")
            }
            preceding = value
        }
        _ = try number(hdr, "detail", path: "hdr_tone_curve", range: 0...40)
        let post = try dictionary(object["post_processing"], path: "post_processing")
        for key in ["grain", "denoise", "vignette", "devignette"] {
            _ = try number(post, key, path: "post_processing", range: 0...100)
        }
    }

    private static func generatedJSONCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A valid JSON array or scalar is not a generated plan, even if it embeds an object.
        if let root = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]),
           !(root is [String: Any]) {
            return [trimmed]
        }
        var candidates = [trimmed] + fencedCodeBlocks(in: text)
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let char = text[index]
            if depth == 0 {
                if char == "{" { start = index; depth = 1 }
                continue
            }
            if escaped { escaped = false; continue }
            if inString && char == "\\" { escaped = true; continue }
            if char == "\"" { inString.toggle(); continue }
            if inString { continue }
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0, let start { candidates.append(String(text[start...index])) }
            }
        }
        // Never synthesize closing braces: a truncated generation is a failed generation.
        var seen: Set<String> = []
        return candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func sanitizeDirtyJSON(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripMarkdownFence(result)
        result = normalizePunctuation(result)
        result = stripComments(result)
        result = quoteSingleQuotedStrings(result)
        result = quoteBareObjectKeys(result)
        result = replacePythonLiterals(result)
        result = result.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return result.unicodeScalars.filter {
            !$0.properties.isNoncharacterCodePoint &&
            ($0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t")
        }.map { String($0) }.joined()
    }

    private static func jsonCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }
        candidates.append(contentsOf: fencedCodeBlocks(in: text))
        if let object = firstBalancedJSONObject(in: text) {
            candidates.append(object)
        } else if let firstBrace = text.firstIndex(of: "{"),
                  let lastBrace = text.lastIndex(of: "}"),
                  firstBrace <= lastBrace {
            candidates.append(String(text[firstBrace...lastBrace]))
        } else if let repaired = repairedJSONObject(in: text) {
            candidates.append(repaired)
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func fencedCodeBlocks(in text: String) -> [String] {
        let pattern = #"```(?:[A-Za-z0-9_-]+)?\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var inString = false
        var stringDelimiter: Character = "\""
        var escaped = false

        for index in text.indices {
            let char = text[index]
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if (char == "\"" || char == "'") {
                if inString {
                    if char == stringDelimiter {
                        inString = false
                    }
                } else {
                    inString = true
                    stringDelimiter = char
                }
                continue
            }
            if inString {
                continue
            }
            if char == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if char == "}", depth > 0 {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
            }
        }
        return nil
    }

    private static func repairedJSONObject(in text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }
        var candidate = String(text[firstBrace...])
        var stack: [Character] = []
        var inString = false
        var delimiter: Character = "\""
        var escaped = false

        for char in candidate {
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" || char == "'" {
                if inString {
                    if char == delimiter {
                        inString = false
                    }
                } else {
                    inString = true
                    delimiter = char
                }
                continue
            }
            guard !inString else { continue }
            if char == "{" {
                stack.append("}")
            } else if char == "[" {
                stack.append("]")
            } else if (char == "}" || char == "]"), stack.last == char {
                stack.removeLast()
            }
        }

        if inString {
            candidate.append(delimiter)
        }
        while let closer = stack.popLast() {
            candidate.append(closer)
        }
        return candidate
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"^\s*```(?:json|JSON)?\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*```\s*$"#, with: "", options: .regularExpression)
        return result
    }

    private static func normalizePunctuation(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "„", with: "\"")
            .replacingOccurrences(of: "‟", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "｛", with: "{")
            .replacingOccurrences(of: "｝", with: "}")
            .replacingOccurrences(of: "［", with: "[")
            .replacingOccurrences(of: "］", with: "]")
    }

    private static func stripComments(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var delimiter: Character = "\""
        var escaped = false

        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)

            if escaped {
                output.append(char)
                escaped = false
                index = next
                continue
            }
            if char == "\\" && inString {
                output.append(char)
                escaped = true
                index = next
                continue
            }
            if char == "\"" || char == "'" {
                if inString {
                    if char == delimiter {
                        inString = false
                    }
                } else {
                    inString = true
                    delimiter = char
                }
                output.append(char)
                index = next
                continue
            }
            if !inString, char == "/", next < text.endIndex {
                let second = text[next]
                if second == "/" {
                    index = text[next...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? text.endIndex
                    continue
                }
                if second == "*" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        let after = text.index(after: cursor)
                        if text[cursor] == "*", after < text.endIndex, text[after] == "/" {
                            index = text.index(after: after)
                            break
                        }
                        cursor = after
                    }
                    if cursor >= text.endIndex {
                        index = text.endIndex
                    }
                    continue
                }
            }
            output.append(char)
            index = next
        }
        return output
    }

    private static func quoteSingleQuotedStrings(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inDoubleString = false
        var escaped = false

        while index < text.endIndex {
            let char = text[index]
            if escaped {
                output.append(char)
                escaped = false
                index = text.index(after: index)
                continue
            }
            if char == "\\" {
                output.append(char)
                escaped = true
                index = text.index(after: index)
                continue
            }
            if char == "\"" {
                inDoubleString.toggle()
                output.append(char)
                index = text.index(after: index)
                continue
            }
            if char == "'", !inDoubleString {
                output.append("\"")
                index = text.index(after: index)
                while index < text.endIndex {
                    let inner = text[index]
                    if inner == "\\" {
                        output.append(inner)
                        let next = text.index(after: index)
                        if next < text.endIndex {
                            output.append(text[next])
                            index = text.index(after: next)
                        } else {
                            index = next
                        }
                        continue
                    }
                    if inner == "\"" {
                        output.append("\\\"")
                    } else if inner == "'" {
                        output.append("\"")
                        index = text.index(after: index)
                        break
                    } else {
                        output.append(inner)
                    }
                    index = text.index(after: index)
                }
                continue
            }
            output.append(char)
            index = text.index(after: index)
        }
        return output
    }

    private static func quoteBareObjectKeys(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"([{\[,]\s*)([A-Za-z_][A-Za-z0-9_-]*)(\s*:)"#,
            with: #"$1"$2"$3"#,
            options: .regularExpression
        )
    }

    private static func replacePythonLiterals(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"\bTrue\b"#, with: "true", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\bFalse\b"#, with: "false", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\bNone\b"#, with: "null", options: .regularExpression)
        return result
    }
}
