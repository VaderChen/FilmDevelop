import Foundation

public struct PhotoStylePlan: Codable, Sendable {
    public static let currentSchemaVersion = 6

    public struct ToneAdjustment: Codable, Equatable, Sendable {
        public var baseTone: Int
        public var exposure: Int
        public var contrast: Int
        public var softness: Int
        public var grain: Int
        public var highlights: Int
        public var shadows: Int
        public var fade: Int
        public var warmth: Int
        public var tint: Int
        public var mapping: Int

        public init(
            baseTone: Int,
            exposure: Int,
            contrast: Int,
            softness: Int,
            grain: Int,
            highlights: Int,
            shadows: Int,
            fade: Int,
            warmth: Int,
            tint: Int,
            mapping: Int = 0
        ) {
            self.baseTone = baseTone
            self.exposure = exposure
            self.contrast = contrast
            self.softness = softness
            self.grain = grain
            self.highlights = highlights
            self.shadows = shadows
            self.fade = fade
            self.warmth = warmth
            self.tint = tint
            self.mapping = mapping
        }

        enum CodingKeys: String, CodingKey {
            case baseTone = "base_tone"
            case exposure
            case legacyBrightness = "brightness"
            case contrast
            case softness
            case grain
            case highlights
            case shadows
            case fade
            case warmth
            case tint
            case mapping
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            baseTone = container.decodeLossyIntIfPresent(forKey: .baseTone) ?? 0
            exposure = container.decodeLossyIntIfPresent(forKey: .exposure)
                ?? container.decodeLossyIntIfPresent(forKey: .legacyBrightness)
                ?? 0
            contrast = container.decodeLossyIntIfPresent(forKey: .contrast) ?? 0
            softness = container.decodeLossyIntIfPresent(forKey: .softness) ?? 0
            grain = container.decodeLossyIntIfPresent(forKey: .grain) ?? 0
            highlights = container.decodeLossyIntIfPresent(forKey: .highlights) ?? 0
            shadows = container.decodeLossyIntIfPresent(forKey: .shadows) ?? 0
            fade = container.decodeLossyIntIfPresent(forKey: .fade) ?? 0
            warmth = container.decodeLossyIntIfPresent(forKey: .warmth) ?? 0
            tint = container.decodeLossyIntIfPresent(forKey: .tint) ?? 0
            mapping = container.decodeLossyIntIfPresent(forKey: .mapping) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(baseTone, forKey: .baseTone)
            try container.encode(exposure, forKey: .exposure)
            try container.encode(contrast, forKey: .contrast)
            try container.encode(softness, forKey: .softness)
            try container.encode(grain, forKey: .grain)
            try container.encode(highlights, forKey: .highlights)
            try container.encode(shadows, forKey: .shadows)
            try container.encode(fade, forKey: .fade)
            try container.encode(warmth, forKey: .warmth)
            try container.encode(tint, forKey: .tint)
            try container.encode(mapping, forKey: .mapping)
        }
    }

    public struct ToneZones: Codable, Equatable, Sendable {
        public var shadows: ToneAdjustment
        public var midtones: ToneAdjustment
        public var highlights: ToneAdjustment

        public init(
            shadows: ToneAdjustment,
            midtones: ToneAdjustment,
            highlights: ToneAdjustment
        ) {
            self.shadows = shadows
            self.midtones = midtones
            self.highlights = highlights
        }

        enum CodingKeys: String, CodingKey {
            case shadows
            case midtones
            case highlights
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shadows = (try? container.decode(ToneAdjustment.self, forKey: .shadows)) ?? .zero
            midtones = (try? container.decode(ToneAdjustment.self, forKey: .midtones)) ?? .zero
            highlights = (try? container.decode(ToneAdjustment.self, forKey: .highlights)) ?? .zero
        }
    }

    public struct HDRToneCurve: Codable, Equatable, Sendable {
        public var black: Int
        public var shadows: Int
        public var midtones: Int
        public var highlights: Int
        public var white: Int
        public var detail: Int

        public init(
            black: Int,
            shadows: Int,
            midtones: Int,
            highlights: Int,
            white: Int,
            detail: Int
        ) {
            self.black = black
            self.shadows = shadows
            self.midtones = midtones
            self.highlights = highlights
            self.white = white
            self.detail = detail
        }

        public var hasVisibleEffect: Bool {
            black != 0 || shadows != 25 || midtones != 50
                || highlights != 75 || white != 100 || detail > 0
        }

        enum CodingKeys: String, CodingKey {
            case black
            case shadows
            case midtones
            case highlights
            case white
            case detail
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            black = container.decodeLossyIntIfPresent(forKey: .black) ?? 0
            shadows = container.decodeLossyIntIfPresent(forKey: .shadows) ?? 25
            midtones = container.decodeLossyIntIfPresent(forKey: .midtones) ?? 50
            highlights = container.decodeLossyIntIfPresent(forKey: .highlights) ?? 75
            white = container.decodeLossyIntIfPresent(forKey: .white) ?? 100
            detail = container.decodeLossyIntIfPresent(forKey: .detail) ?? 0
        }
    }

    public struct PostProcessing: Codable, Sendable {
        public var grain: Int
        public var denoise: Int
        public var vignette: Int
        public var devignette: Int

        public init(
            grain: Int,
            denoise: Int,
            vignette: Int,
            devignette: Int
        ) {
            self.grain = grain
            self.denoise = denoise
            self.vignette = vignette
            self.devignette = devignette
        }

        enum CodingKeys: String, CodingKey {
            case grain
            case denoise
            case vignette
            case devignette
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            grain = container.decodeLossyIntIfPresent(forKey: .grain) ?? 0
            denoise = container.decodeLossyIntIfPresent(forKey: .denoise) ?? 0
            vignette = container.decodeLossyIntIfPresent(forKey: .vignette) ?? 0
            devignette = container.decodeLossyIntIfPresent(forKey: .devignette) ?? 0
        }
    }

    public var sceneSummary: String
    public var recommendedStyle: String
    public var editPrompt: String
    public var negativePrompt: String
    public var colorMode: String
    public var toneZones: ToneZones
    public var hdrToneCurve: HDRToneCurve?
    public var strength: Int
    public var backgroundBlur: Int
    public var skinWhitening: Int
    public var skinSmoothing: Int
    public var postProcessing: PostProcessing
    public var filmEffects: PhotoFilmEffects
    public var editorControls: PhotoEditorControls?
    public var schemaVersion: Int

    public init(
        sceneSummary: String,
        recommendedStyle: String,
        editPrompt: String,
        negativePrompt: String,
        colorMode: String,
        toneZones: ToneZones,
        hdrToneCurve: HDRToneCurve? = nil,
        strength: Int,
        backgroundBlur: Int,
        skinWhitening: Int,
        skinSmoothing: Int,
        postProcessing: PostProcessing,
        filmEffects: PhotoFilmEffects = .neutral,
        editorControls: PhotoEditorControls? = nil,
        schemaVersion: Int = 2
    ) {
        self.sceneSummary = sceneSummary
        self.recommendedStyle = recommendedStyle
        self.editPrompt = editPrompt
        self.negativePrompt = negativePrompt
        self.colorMode = colorMode
        self.toneZones = toneZones
        self.hdrToneCurve = hdrToneCurve
        self.strength = strength
        self.backgroundBlur = backgroundBlur
        self.skinWhitening = skinWhitening
        self.skinSmoothing = skinSmoothing
        self.postProcessing = postProcessing
        self.filmEffects = filmEffects
        self.editorControls = editorControls
        self.schemaVersion = editorControls == nil ? schemaVersion : Self.currentSchemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case editorControls = "editor_controls"
        case schemaVersion = "schema_version"
        case filmEffects = "film_effects"
        case sceneSummary = "scene_summary"
        case recommendedStyle = "recommended_style"
        case editPrompt = "edit_prompt"
        case negativePrompt = "negative_prompt"
        case colorMode = "color_mode"
        case toneZones = "tone_zones"
        case hdrToneCurve = "hdr_tone_curve"
        case strength
        case backgroundBlur = "background_blur"
        case skinWhitening = "skin_whitening"
        case skinSmoothing = "skin_smoothing"
        case postProcessing = "post_processing"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "The object contains no photo style plan fields."
            ))
        }
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported photo style plan schema version.")
        }
        editorControls = try container.decodeIfPresent(PhotoEditorControls.self, forKey: .editorControls)
        filmEffects = try container.decodeIfPresent(PhotoFilmEffects.self, forKey: .filmEffects) ?? .neutral
        sceneSummary = container.decodeStringIfPresent(forKey: .sceneSummary) ?? ""
        recommendedStyle = container.decodeStringIfPresent(forKey: .recommendedStyle) ?? ""
        editPrompt = container.decodeStringIfPresent(forKey: .editPrompt) ?? ""
        negativePrompt = container.decodeStringIfPresent(forKey: .negativePrompt) ?? ""
        colorMode = container.decodeStringIfPresent(forKey: .colorMode) ?? "color"
        toneZones = (try? container.decode(ToneZones.self, forKey: .toneZones)) ?? .zero
        hdrToneCurve = try? container.decode(HDRToneCurve.self, forKey: .hdrToneCurve)
        strength = container.decodeLossyIntIfPresent(forKey: .strength) ?? 80
        backgroundBlur = container.decodeLossyIntIfPresent(forKey: .backgroundBlur) ?? 0
        skinWhitening = container.decodeLossyIntIfPresent(forKey: .skinWhitening) ?? 0
        skinSmoothing = container.decodeLossyIntIfPresent(forKey: .skinSmoothing) ?? 0
        postProcessing = (try? container.decode(PostProcessing.self, forKey: .postProcessing)) ?? .zero
    }
}

private extension PhotoStylePlan.ToneAdjustment {
    static let zero = PhotoStylePlan.ToneAdjustment(
        baseTone: 0,
        exposure: 0,
        contrast: 0,
        softness: 0,
        grain: 0,
        highlights: 0,
        shadows: 0,
        fade: 0,
        warmth: 0,
        tint: 0,
        mapping: 0
    )
}

private extension PhotoStylePlan.ToneZones {
    static let zero = PhotoStylePlan.ToneZones(
        shadows: .zero,
        midtones: .zero,
        highlights: .zero
    )
}

private extension PhotoStylePlan.PostProcessing {
    static let zero = PhotoStylePlan.PostProcessing(
        grain: 0,
        denoise: 0,
        vignette: 0,
        devignette: 0
    )
}

private extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return min(100, max(-100, value))
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return safeParameter(from: value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return safeParameter(from: number)
        }
        return nil
    }

    private func safeParameter(from value: Double) -> Int? {
        // Every numeric plan field is a percentage or a signed correction.
        // Reject non-finite values and clamp before converting, avoiding traps
        // both here and in downstream integer arithmetic for extreme outputs.
        guard value.isFinite else { return nil }
        return Int(min(100, max(-100, value.rounded())))
    }

    func decodeStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}
