import Foundation
import PhotoStyleShared

/// One contract for the model prompt and constrained JSON generation. Customized
/// instructions replace the aesthetic defaults; numeric validation still applies.
enum PhotoStyleAIRequest {
    static let maxOutputTokens = 3072
    static let contextLimit = 12288
    static func usesCustomPrompt(_ prompt: String?, style: PhotoStyle) -> Bool {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return false }
        return !style.llmDescriptions.values.contains(prompt)
    }

    static let systemInstruction = """
    You translate the user's photo-editing request into executable slider values after inspecting the image.
    Return exactly one complete JSON object matching the schema. No markdown, reasoning or extra text.
    User instructions have priority over aesthetic defaults. Explicit numbers are absolute slider values, not percentages of a preset. Copy requested numbers exactly within the legal ranges. A value of 0 means disabled or neutral; never replace it with a stylistic minimum. Apply a request for all tonal zones to shadows, midtones AND highlights.
    Scope: "other/remaining/rest/其餘/其他" affects ONLY unspecified controls. Explicit assignments survive a later blanket-neutral instruction; a correction must name the same control. 「其餘／其他歸零」不包括前面已明確指定數值的項目。
    Every requested visual effect must be expressed in numeric fields. scene_summary, edit_prompt and negative_prompt are descriptions only and do not change the image. Keep each description under 80 characters, in the user's language. Do not merely describe a requested adjustment while leaving its values unchanged.
    Field meanings and ranges:
    - schema_version: exactly 6. Include every field of film_effects and editor_controls, even when disabled. All editor_controls numbers support decimals.
    - strength (風格強度): 0...100, the master amount of the style and its adjustments. Global and tonal-zone exposure slider values are multiplied by strength/100 before their EV conversion; consider this attenuation when choosing an exposure correction.
    - tone_zones.shadows/midtones/highlights (暗部/中間調/亮部): each contains all eleven controls below.
    - base_tone: -100...100, saturation adjustment (negative desaturates, positive saturates).
    - exposure (曝光): -100...100, 0 is neutral. Positive 20 = +1 EV, 50 = +2.5 EV, 100 = +5 EV; negative -50 = -1 EV and -100 = -2 EV. These drive adaptive shadow/highlight correction, not uniform gain.
    - contrast (對比): -100...100, positive increases separation, negative reduces it.
    - warmth (暖色): -100...100, positive warmer, negative cooler. tint (色偏): positive magenta, negative green.
    - highlights: -100...100, positive recovers highlights, negative lifts highlights. shadows: positive lifts shadows, negative deepens them.
    - softness, grain, fade, mapping: 0...100; 0 disables that control. mapping is the amount of the selected style's additional tonal-zone color mapping.
    - background_blur, skin_whitening, skin_smoothing: 0...100; 0 disables each effect.
    - post_processing.grain/denoise/vignette/devignette: 0...100. 「顆粒量／全域顆粒」 (grain amount/global grain) is post_processing.grain. 「三區／分區顆粒」 (tonal grain) is tone_zones.shadows/midtones/highlights.grain. These are independent: zero in all three zones does not zero or overwrite an explicitly requested global grain amount. The stronger global or zone grain is rendered. "Remove ALL grain" disables both. Vignette darkens edges; devignette brightens edges.
    - hdr_tone_curve: output luminance at input positions black=0, shadows=25, midtones=50, highlights=75, white=100. All outputs are 0...100 in nondecreasing order; detail is 0...40. Neutral/disabled HDR is exactly 0,25,50,75,100 with detail 0. A neutral curve is valid; never force HDR or reuse an old curve.
    - film_effects.grain_mode: exactly "emulsion". All grain uses Poisson polygon capture before development. grain_size: 0.5...4 pixels at a 3000-pixel full-frame long edge (neutral 1); grain_clumping and grain_chroma: 0...100 (neutral 0). Grain amount comes from post_processing.grain and tonal-zone grain. Zero amounts disable grain. Old legacy/structured/crystal overlays have been replaced.
    - film_effects.bloom_amount: 0...100, neutral scattered highlight glow; bloom_radius: 0.05...2 percent of the full-frame long edge (Gaussian sigma, neutral 0.4); bloom_threshold: 0...100, linear-light brightness threshold divided by 100 (neutral 75). Express bloom/亮部柔光 here, not as full-image softness.
    - film_effects.halation_amount: 0...100, red-orange highlight-edge glow; halation_radius: 0.01...0.3 percent of the full-frame long edge (neutral 0.1); halation_threshold: 0...100 (neutral 75). Bloom and halation are independent; use amount 0 to disable each, regardless of radius/threshold.
    - film_effects.monochrome_filter: "none", "yellow", "orange", "red", or "green". monochrome_filter_strength: 0...100 (neutral 100); 0 disables its filtering. Only monochrome rendering applies this pre-grayscale color sensitivity: yellow/orange/red increasingly darken blue sky; green favors foliage. It never adds a tint or changes a color style to monochrome.
    - film_effects.color_model: exactly "spectral": LHTSS radiance reconstruction, multi-band dye transmission and a separate print stage. The analytic three-band curve has been replaced. This switch only applies to film-stock styles. print_exposure: -16...16 EV (neutral 0; standard UI range -8...8 EV, extended range -16...16 EV), luminance-only input exposure compensation before emulsion, development and film color: positive values brighten and negative values darken ALL film stocks, including color negatives, B&W negatives and reversal film. Exposure preserves source chromaticity; never invert the requested value. print_contrast: 0...100 (neutral 50), print contrast for negative film or viewing-density contrast for reversal film. The same positive-bright exposure convention applies to ordinary styles. Exposure also applies before ordinary style signatures; contrast applies through the neutral digital print stage after the signature. Neutral values preserve the existing appearance.
    - film_effects.development_amount: 0...100 (neutral 0 disables), shared-developer depletion and diffusion before the film curve. development_time: 0...100 (neutral 50), relative reaction time; development_diffusion: 0.02...1 percent of full-frame long edge (neutral 0.15); development_agitation: 0...100 (neutral 50), developer replenishment. Do not map these controls to ordinary contrast or softness.
    - grain_mode "emulsion" uses Poisson polygon footprints and layered light absorption BEFORE development, including backscatter controlled by halation_amount/radius/threshold. It is not a second output grain overlay. print_illuminant and view_illuminant independently select one of \(PhotoFilmEffects.Illuminant.allCases.map { "\"\($0.rawValue)\" (\($0.title))" }.joined(separator: ", ")) (default "reference"); both are available for ordinary styles and film stocks. Ordinary styles use neutral digital printing; monochrome styles remain grayscale. Reversal bypasses the print light. blackbody6500 is a blackbody approximation, not measured D65. Do not invent calibration coefficients; the imported measured calibration is preserved outside the AI plan.
    - New film controls default to color_model spectral, print_exposure 0, print_contrast 50, development_amount 0, development_time 50, development_diffusion 0.15 and development_agitation 50, unless the selected film baseline or explicit request overrides them. New film stocks supply spectral and emulsion defaults. Never invent measured film chemistry.
    - film_effects.scanner_profile: off (existing print/view pipeline), neutral (direct film scan), warmCool (warm midtones, cool highlights), softPortrait (gentler contrast and saturation), vivid (stronger contrast and saturation), coolClean (cooler clean tones), fadedVintage (warm muted colors and lifted blacks). Film stocks and the original look default to neutral scanning. Digital camera simulations do not support scanning: always use off for them. Preserve an explicitly supplied scanner profile; use neutral when no scanner preference is supplied. Original images use scan color grading without negative inversion or dye separation. scanner_illuminant uses the same enum as print_illuminant. print_exposure and print_contrast control exposure and contrast in both print and scan output. scan_exposure and scan_contrast are legacy fields: always leave them at 0 and 50. scan_saturation: 0...100, neutral 50. scan_density_correction: 0...100, default 100 removes dye-channel overlap in log density. scan_flare: 0...100, default 0 adds scanner stray light before inversion. scan_midtone_warmth and scan_highlight_warmth: -100...100, default 0; positive warm yellow, negative cool blue, tapered near white. These controls apply only when scanner_profile is enabled; print/view illuminants are bypassed, while print_exposure and print_contrast remain active. For monochrome stocks saturation and warmth do not add color. Reversal film bypasses negative inversion and density correction.
    - Material controls are artistic approximations, not measured chemistry. Keep neutral values unless requested: layer_response 0...100 (neutral 0); coupler_amount 0...100 (neutral 0); coupler_radius 0...1 (neutral 0.1); film_width_mm 8...120 (neutral 36); grain_distribution 0...100 (neutral 0); emulsion_mtf 0...100 (neutral 0); paper_scatter 0...100 (neutral 0); paper_white 80...100 (neutral 100); paper_density_offset -1...1 (neutral 0); reciprocity_amount 0...100 (neutral 0); exposure_seconds 0.0001...3600 (neutral 1); halation_base 0...100 (neutral 50); silver_retention 0...100 (neutral 0); developer_temperature 10...40 (neutral 20); developer_activity 20...200 (neutral 100). paper_profile: reference/glossy/matte/warmFiber (neutral reference). scanner_source: film (default, direct film scan) or paper (optical print then positive photo scan). Paper controls apply to optical printing including paper scans, but not direct film scanning or reversal film. Exposure seconds is virtual, not recovered EXIF.
    - All film_effects numbers support decimals; copy explicit decimal values exactly. Keep neutral defaults for unrequested film effects; do not inject glow into an existing style. For a request to neutralize everything, use grain_mode emulsion, grain_size 1, grain_clumping/chroma 0, both glow amounts 0 with their neutral radii/thresholds, monochrome_filter none and strength 100.
    - editor_controls.exposure, white_balance_warmth, white_balance_tint, contrast: -100...100, neutral 0. These are the independent 全圖曝光、全圖色溫、全圖色偏、全圖對比 sliders. A request without a tonal zone targets the global control; only requests naming 暗部、中調、亮部 or 三區 target tone_zones. Do not duplicate a global request across zones. Exposure uses the same nonlinear EV scale documented above. brightness: 0...100, neutral 50 (legacy brightness correction).
    - editor_controls.hdr_amount: 0...100, controls the HDR 模擬 slider independently of hdr_tone_curve. To disable HDR set hdr_amount 0 and a neutral curve; to enable it supply both a nonzero amount and a non-neutral curve. The user's app-level HDR switch still takes precedence.
    - editor_controls.crop_aspect_ratio: original (uncropped), source (crop locked to the original image aspect ratio), free, threeTwo (3:2), oneOne (1:1), fourThree (4:3), sixteenNine (16:9). Fixed ratios follow portrait/landscape orientation. crop_scale: 20...100, retained size for fixed-ratio crops. crop_width/crop_height: 20...100, independent retained percentages for free crop. crop_horizontal_position/crop_vertical_position: -100...100; -100 left/top, 0 center, +100 right/bottom. Position spans only the available crop travel. crop_rotation: -45...45 degrees, positive clockwise; 0 means no rotation. Rotation automatically fills the image rectangle. Crop controls change the exported composition; they are not preview zoom/pan.
    - editor_controls.frame_enabled/date_enabled: JSON true/false. frame_style: whitePaperThin (白色細框), whitePaperWide (白色寬框), whitePaperPolaroid (拍立得), blackLine (黑色細框), filmStrip (底片框), cleanInset (留白內框). date_style: numeric (YYYY.MM.DD), slash (YY/MM/DD), compact (YYYYMMDD), japanese (YYYY年M月D日). Enabling a style requires its enabled flag. Dates use the app's current date.
    - Preserve the current crop, frame and date settings supplied in the user message unless explicitly requested to change them. When the user explicitly resets these settings, use original crop, size 100, centered position 0, both enabled flags false, frame whitePaperThin and date numeric. Never crop or add a date/frame just because a style is retro.
    The selected style supplies the base look. color_mode must match its rendering mode, given in the user message. Object replacement, masks for arbitrary objects, and changing the selected style are not available through this schema; do not claim to have performed them.
    Before returning, check every explicit number, requested tonal zone, negation, and disabled effect against the numeric fields. Include every field even when it is zero. Schema (values illustrate neutral controls, not a preset to copy):
    {"schema_version":6,"scene_summary":"","recommended_style":"","edit_prompt":"","negative_prompt":"","color_mode":"color","tone_zones":{"shadows":{"base_tone":0,"exposure":0,"contrast":0,"softness":0,"grain":0,"highlights":0,"shadows":0,"fade":0,"warmth":0,"tint":0,"mapping":0},"midtones":{"base_tone":0,"exposure":0,"contrast":0,"softness":0,"grain":0,"highlights":0,"shadows":0,"fade":0,"warmth":0,"tint":0,"mapping":0},"highlights":{"base_tone":0,"exposure":0,"contrast":0,"softness":0,"grain":0,"highlights":0,"shadows":0,"fade":0,"warmth":0,"tint":0,"mapping":0}},"hdr_tone_curve":{"black":0,"shadows":25,"midtones":50,"highlights":75,"white":100,"detail":0},"strength":50,"background_blur":0,"skin_whitening":0,"skin_smoothing":0,"post_processing":{"grain":0,"denoise":0,"vignette":0,"devignette":0},"film_effects":{"layer_response":0,"coupler_amount":0,"coupler_radius":0.1,"film_width_mm":36,"grain_distribution":0,"emulsion_mtf":0,"paper_scatter":0,"paper_white":100,"paper_density_offset":0,"reciprocity_amount":0,"exposure_seconds":1,"halation_base":50,"silver_retention":0,"developer_temperature":20,"developer_activity":100,"paper_profile":"reference","grain_mode":"emulsion","grain_size":1,"grain_clumping":0,"grain_chroma":0,"bloom_amount":0,"bloom_radius":0.4,"bloom_threshold":75,"halation_amount":0,"halation_radius":0.1,"halation_threshold":75,"monochrome_filter":"none","monochrome_filter_strength":100,"color_model":"spectral","print_exposure":0,"print_contrast":50,"print_illuminant":"reference","view_illuminant":"reference","development_amount":0,"development_time":50,"development_diffusion":0.15,"development_agitation":50,"scanner_source":"film","scanner_profile":"neutral","scanner_illuminant":"reference","scan_exposure":0.0,"scan_contrast":50.0,"scan_saturation":50.0,"scan_density_correction":100.0,"scan_flare":0.0,"scan_midtone_warmth":0.0,"scan_highlight_warmth":0.0},"editor_controls":{"exposure":0,"white_balance_warmth":0,"white_balance_tint":0,"contrast":0,"brightness":50,"hdr_amount":0,"crop_aspect_ratio":"original","crop_rotation":0,"crop_scale":100,"crop_width":100,"crop_height":100,"crop_horizontal_position":0,"crop_vertical_position":0,"frame_enabled":false,"frame_style":"whitePaperThin","date_enabled":false,"date_style":"numeric"}}
    The JSON above is a field/layout reference, not a numeric starting point. Assign explicit user values first, then fill unspecified controls. Do not copy the reference's zero over a requested nonzero value.
    Scope examples (partial field mappings only; your final answer must include the complete schema):
    Request: 「顆粒量37，三區顆粒0，其他效果量0。」 → {"post_processing":{"grain":37},"tone_zones":{"shadows":{"grain":0},"midtones":{"grain":0},"highlights":{"grain":0}}}
    Request: 「全域顆粒0，暗部顆粒24，其餘效果關閉。」 → {"post_processing":{"grain":0},"tone_zones":{"shadows":{"grain":24},"midtones":{"grain":0},"highlights":{"grain":0}}}
    The example numbers belong only to those example requests. Use the actual user's numbers, keeping global and zonal assignments separate.
    """

    static func userContent(style: PhotoStyle, prompt: String?, imageMarker: String, baseAdjustment: StyleAdjustment = .default,
                            imageAnalysis: String? = nil) -> String {
        let active = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = active?.isEmpty == false ? active! : style.llmDescription
        let editor = PhotoStyleAdjustmentMapper.editorControls(from: baseAdjustment)
        let editorJSON = (try? JSONEncoder().encode(editor)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let prefix = "\(imageMarker)\nSelected base style: \(style.title)\nRendering color_mode: \(style.isMonochrome ? "monochrome" : "color")\nCurrent editor_controls (preserve crop/frame/date unless requested): \(editorJSON)"
        if usesCustomPrompt(prompt, style: style) {
            return """
            \(prefix)
            The following is the user's customized editing target and REPLACES the default aesthetic guidance. Do not reintroduce film grain, fade, softness, exposure correction, or color casts against this request. Image analysis may guide unspecified controls but may never reverse a requested direction or change a requested number. If the user says all other controls are neutral, neutralize ONLY unspecified controls: set their effect amounts to zero, use the neutral HDR curve and documented neutral film shape/filter values where not explicitly assigned. Preserve specifically requested amounts, dimensions, thresholds and filters.
            User request:
            \(instructions)
            Preserving crop/frame/date does not preserve unrelated tonal controls. If the user resets all other image effects, reset unspecified global white balance, tint and contrast as well; preserve any explicitly assigned values.
            Before returning, match each explicitly requested value to its own field. 顆粒量／全域顆粒 is post_processing.grain; 三區／分區顆粒 controls only the three tone_zones grain fields. 「其他／其餘」 excludes these explicit assignments. Return the complete executable JSON now.
            """
        }
        let filmBaseline: String
        if let stock = style.filmStock,
           let data = try? JSONEncoder().encode(stock.defaultEffects),
           let effects = String(data: data, encoding: .utf8) {
            filmBaseline = "This selected film explicitly requests post_processing.grain = \(stock.defaultGrain) and film_effects = \(effects). These baseline values describe film texture and printing, NOT the photograph's exposure correction: the density kernel itself does not supply grain. Keep all tonal-zone grain at zero unless needed; it adds to the global baseline. Use editor_controls.exposure and tone_zones to correct the photograph independently of these film defaults. Do not copy neutral film exposure into every image correction."
        } else {
            filmBaseline = ""
        }
        return """
        \(prefix)
        \(imageAnalysis ?? "")
        Editing target: \(instructions)
        Suggested starting ranges, to adapt to the image: \(style.llmParameterGuidance)
        First correct the photograph's exposure, then preserve the selected style. Inspect the main subject and faces separately from the background: a bright sky does not mean a backlit subject is well exposed. If the subject is unintentionally too dark, use editor_controls.exposure for the main correction: its adaptive response lifts dark detail while protecting bright areas. Use shadow/midtone controls for residual local correction, not as a substitute for a substantial exposure deficit. Remember that strength attenuates these controls. Keep exposure neutral for an already well-exposed image or an intentionally dark scene. Do not brighten all zones just to simulate a faded style. HDR may remain neutral when no compression is needed.
        Avoid correcting the same shadow deficit repeatedly: global exposure, zone exposure and the shadows recovery control compound. Choose one primary correction and leave the others neutral unless a separate remaining problem needs them. Preserve dark hair, black clothing and scene black points; a readable face must not turn the photograph into gray haze. Do not increase style strength merely to brighten the photograph.
        \(filmBaseline)
        Before returning, compare the numeric exposure fields with your visual assessment. If scene_summary or edit_prompt says the subject needs brightening, at least one corresponding executable exposure/shadow control must do so. Film texture defaults alone are not an exposure correction.
        Return the complete executable JSON now.
        """
    }

    /// GBNF constrains syntax, field presence, numeric ranges and string lengths.
    /// It cannot establish semantic adherence; that is checked separately in
    /// model evaluations and the complete-plan decoder.
    static let grammar: String = {
        func literal(_ value: String) -> String { String(decoding: try! JSONEncoder().encode(value), as: UTF8.self) }
        func object(_ fields: [(String, String)]) -> String {
            let body = fields.map { literal("\"\($0.0)\"") + " ws \":\" ws " + $0.1 }
                .joined(separator: " \",\" ws ")
            return "\"{\" ws " + body + " \"}\" ws"
        }
        let signed = ["base_tone", "exposure", "contrast", "highlights", "shadows", "warmth", "tint"]
        let toneFields = ["base_tone", "exposure", "contrast", "softness", "grain", "highlights", "shadows", "fade", "warmth", "tint", "mapping"]
        let rootFields: [(String, String)] = [
            ("schema_version", "version"), ("scene_summary", "string"), ("recommended_style", "string"), ("edit_prompt", "string"), ("negative_prompt", "string"),
            ("color_mode", "mode"), ("tone_zones", "zones"), ("hdr_tone_curve", "hdr"), ("strength", "unsigned"),
            ("background_blur", "unsigned"), ("skin_whitening", "unsigned"), ("skin_smoothing", "unsigned"), ("post_processing", "post"), ("film_effects", "film"), ("editor_controls", "editor")
        ]
        return [
            "root ::= " + object(rootFields),
            "zones ::= " + object([("shadows", "tone"), ("midtones", "tone"), ("highlights", "tone")]),
            "tone ::= " + object(toneFields.map { ($0, signed.contains($0) ? "signed" : "unsigned") }),
            "hdr ::= " + object(["black", "shadows", "midtones", "highlights", "white"].map { ($0, "unsigned") } + [("detail", "detail")]),
            "post ::= " + object(["grain", "denoise", "vignette", "devignette"].map { ($0, "unsigned") }),
            "film ::= " + object([
                ("grain_mode", "grain-mode"), ("grain_size", "grain-size"),
                ("grain_clumping", "percent"), ("grain_chroma", "percent"),
                ("bloom_amount", "percent"), ("bloom_radius", "bloom-radius"), ("bloom_threshold", "percent"),
                ("halation_amount", "percent"), ("halation_radius", "halation-radius"), ("halation_threshold", "percent"),
                ("monochrome_filter", "mono-filter"), ("monochrome_filter_strength", "percent"),
                ("color_model", "film-color"), ("print_exposure", "print-ev"), ("print_contrast", "percent"),
                ("scanner_source", "scanner-source"), ("scanner_profile", "scanner-profile"), ("scanner_illuminant", "illuminant"),
                ("scan_exposure", "print-ev"), ("scan_contrast", "percent"), ("scan_saturation", "percent"), ("scan_density_correction", "percent"), ("scan_flare", "percent"), ("scan_midtone_warmth", "signed-percent"), ("scan_highlight_warmth", "signed-percent"),
                ("print_illuminant", "illuminant"), ("view_illuminant", "illuminant"),
                ("development_amount", "percent"), ("development_time", "percent"),
                ("development_diffusion", "development-radius"), ("development_agitation", "percent"),
                ("layer_response", "material-number"),
                ("coupler_amount", "material-number"),
                ("coupler_radius", "material-number"),
                ("film_width_mm", "material-number"),
                ("grain_distribution", "material-number"),
                ("emulsion_mtf", "material-number"),
                ("paper_scatter", "material-number"),
                ("paper_white", "material-number"),
                ("paper_density_offset", "material-number"),
                ("reciprocity_amount", "material-number"),
                ("exposure_seconds", "material-number"),
                ("halation_base", "material-number"),
                ("silver_retention", "material-number"),
                ("developer_temperature", "material-number"),
                ("developer_activity", "material-number"),
                ("paper_profile", "paper-profile")
            ]),
            "editor ::= " + object([
                ("exposure", "signed-percent"), ("white_balance_warmth", "signed-percent"),
                ("white_balance_tint", "signed-percent"), ("contrast", "signed-percent"),
                ("brightness", "percent"), ("hdr_amount", "percent"),
                ("crop_aspect_ratio", "crop-ratio"), ("crop_rotation", "crop-angle"), ("crop_scale", "crop-size"),
                ("crop_width", "crop-size"), ("crop_height", "crop-size"),
                ("crop_horizontal_position", "signed-percent"), ("crop_vertical_position", "signed-percent"),
                ("frame_enabled", "boolean"), ("frame_style", "frame-style"),
                ("date_enabled", "boolean"), ("date_style", "date-style")
            ]),
            "crop-ratio ::= (" + PhotoEditorControls.enumValues["crop_aspect_ratio"]!.map { literal("\"" + $0 + "\"") }.joined(separator: " | ") + ") ws",
            "frame-style ::= (" + PhotoEditorControls.enumValues["frame_style"]!.map { literal("\"" + $0 + "\"") }.joined(separator: " | ") + ") ws",
            "date-style ::= (" + PhotoEditorControls.enumValues["date_style"]!.map { literal("\"" + $0 + "\"") }.joined(separator: " | ") + ") ws",
            #"boolean ::= ("true" | "false") ws"#,
            #"signed-percent ::= "-"? percent"#,
            #"crop-angle ::= "-"? (([0-9] | [1-3] [0-9] | "4" [0-4]) ("." [0-9]+)? | "45" ("." "0"+)?) ws"#,
            #"crop-size ::= ([2-9] [0-9] ("." [0-9]+)? | "100" ("." "0"+)?) ws"#,
            #"version ::= "6" ws"#,
            #"grain-mode ::= "\"emulsion\"" ws"#,
            "illuminant ::= (" + PhotoFilmEffects.Illuminant.allCases.map { literal("\"" + $0.rawValue + "\"") }.joined(separator: " | ") + ") ws",
            #"scanner-profile ::= ("\"off\"" | "\"neutral\"" | "\"warmCool\"" | "\"softPortrait\"" | "\"vivid\"" | "\"coolClean\"" | "\"fadedVintage\"") ws"#,
            #"film-color ::= "\"spectral\"" ws"#,
            #"print-ev ::= "-"? ([0-3] ("." [0-9]+)? | "4" ("." "0"+)?) ws"#,
            #"material-number ::= "-"? [0-9]+ ("." [0-9]+)? ws"#,
            "scanner-source ::= (" + PhotoFilmEffects.ScannerSource.allCases.map { literal("\"" + $0.rawValue + "\"") }.joined(separator: " | ") + ") ws",
            "paper-profile ::= (" + PhotoFilmEffects.PaperProfile.allCases.map { literal("\"" + $0.rawValue + "\"") }.joined(separator: " | ") + ") ws",
            #"development-radius ::= ("0." ("0" [2-9] [0-9]* | [1-9] [0-9]*) | "1" ("." "0"+)?) ws"#,
            #"mono-filter ::= ("\"none\"" | "\"yellow\"" | "\"orange\"" | "\"red\"" | "\"green\"") ws"#,
            #"percent ::= (([0-9] | [1-9] [0-9]) ("." [0-9]+)? | "100" ("." "0"+)?) ws"#,
            #"grain-size ::= ("0." [5-9] [0-9]* | [1-3] ("." [0-9]+)? | "4" ("." "0"+)?) ws"#,
            #"bloom-radius ::= ("0." ("0" [5-9] [0-9]* | [1-9] [0-9]*) | "1" ("." [0-9]+)? | "2" ("." "0"+)?) ws"#,
            #"halation-radius ::= "0." ("0" [1-9] [0-9]* | [1-2] [0-9]* | "3" "0"*) ws"#,
            #"mode ::= ("\"color\"" | "\"monochrome\"") ws"#,
            #"unsigned ::= ([0-9] | [1-9] [0-9] | "100") ws"#,
            #"signed ::= "-"? ([0-9] | [1-9] [0-9] | "100") ws"#,
            #"detail ::= ([0-9] | [1-3] [0-9] | "40") ws"#,
            #"string ::= "\"" ([^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4})){0,120} "\"" ws"#,
            #"ws ::= [ \t\n\r]*"#
        ].joined(separator: "\n") + "\n"
    }()
}
