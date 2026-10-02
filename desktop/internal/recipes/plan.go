package recipes

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

//go:embed plan.json
var planTemplate []byte

// MapPlan 驗證模型的完整 schema 6 輸出，並轉成共用 schema 12 配方。
// 只接受完整物件，不用舊配方的寬鬆遷移規則補上模型遺漏的控制項。
func (l *Library) MapPlan(text string, base contract.Recipe) (contract.Recipe, error) {
	if len(text) > 128*1024 {
		return base, errors.New("AI 輸出過長")
	}
	candidates := jsonObjects(text)
	var plans []object
	for _, candidate := range candidates {
		var p object
		if json.Unmarshal([]byte(candidate), &p) == nil && p["schema_version"] == float64(6) {
			plans = append(plans, p)
		}
	}
	if len(plans) != 1 {
		return base, errors.New("AI 必須回傳唯一且完整的 schema 6 配方")
	}
	p := plans[0]
	var sample object
	_ = json.Unmarshal(planTemplate, &sample)
	// 舊契約允許材料擴充欄位省略，沿用中性值；核心底片與掃描控制仍須完整。
	film, ok := p["film_effects"].(object)
	if !ok {
		return base, errors.New("AI 缺少底片控制")
	}
	mandatory := strings.Fields("grain_mode grain_size grain_clumping grain_chroma bloom_amount bloom_radius bloom_threshold halation_amount halation_radius halation_threshold monochrome_filter monochrome_filter_strength color_model print_exposure print_contrast print_illuminant view_illuminant development_amount development_time development_diffusion development_agitation scanner_profile scanner_illuminant scan_exposure scan_contrast scan_saturation scan_density_correction scan_flare scan_midtone_warmth scan_highlight_warmth")
	for _, k := range mandatory {
		if _, ok := film[k]; !ok {
			return base, fmt.Errorf("AI 缺少底片欄位：%s", k)
		}
	}
	fullFilm := clone(sample["film_effects"].(object))
	for k, v := range film {
		if k == "developer_chemistry" {
			chem, ok := v.(object)
			if !ok {
				return base, errors.New("顯影配方格式錯誤")
			}
			for key, value := range chem {
				fullFilm[k].(object)[key] = value
			}
		} else {
			fullFilm[k] = v
		}
	}
	p["film_effects"] = fullFilm
	for _, k := range strings.Fields("scene_summary recommended_style edit_prompt negative_prompt") {
		if _, ok := p[k]; !ok {
			p[k] = ""
		}
	}
	if err := validateShape(p, sample, "plan"); err != nil {
		return base, err
	}
	if p["color_mode"] != "color" && p["color_mode"] != "monochrome" {
		return base, errors.New("AI 色彩模式無效")
	}
	if fullFilm["grain_mode"] != "emulsion" || fullFilm["color_model"] != "spectral" {
		return base, errors.New("AI 底片模型必須使用 emulsion／spectral")
	}
	n := func(value any, low, high float64) bool {
		v, ok := value.(float64)
		return ok && !math.IsNaN(v) && !math.IsInf(v, 0) && v >= low && v <= high
	}
	for _, k := range strings.Fields("strength background_blur skin_whitening skin_smoothing") {
		if !n(p[k], 0, 100) {
			return base, fmt.Errorf("AI 數值超出範圍：%s", k)
		}
	}
	zones := p["tone_zones"].(object)
	for region, raw := range zones {
		for k, v := range raw.(object) {
			if !n(v, toneMinimum(k), 100) {
				return base, fmt.Errorf("AI 分區數值超出範圍：%s.%s", region, k)
			}
			raw.(object)[k] = math.Round(v.(float64))
		}
	}
	curve := p["hdr_tone_curve"].(object)
	previous := float64(0)
	for _, k := range strings.Fields("black shadows midtones highlights white") {
		if !n(curve[k], 0, 100) {
			return base, errors.New("AI HDR 數值超出範圍")
		}
		previous = math.Max(previous, math.Round(curve[k].(float64)))
		curve[k] = previous
	}
	if !n(curve["detail"], 0, 40) {
		return base, errors.New("AI HDR 細節超出範圍")
	}
	curve["detail"] = math.Round(curve["detail"].(float64))
	document, err := l.document(base)
	if err != nil {
		return base, err
	}
	document["imageScoped"] = true
	document["sourceToneZones"] = zones
	document["hdrToneCurve"] = curve
	document["intensity"] = p["strength"]
	for k, v := range fullFilm {
		document["filmEffects"].(object)[k] = v
	}
	for region, prefix := range map[string]string{"shadows": "shadow", "midtones": "midtone", "highlights": "highlight"} {
		tone := zones[region].(object)
		for src, dst := range map[string]string{"exposure": "Exposure", "mapping": "Intensity", "warmth": "Warmth", "grain": "Grain"} {
			document[prefix+dst] = tone[src]
		}
	}
	for src, dst := range map[string]string{"background_blur": "backgroundBlur", "skin_whitening": "skinWhitening", "skin_smoothing": "skinSmoothing"} {
		document[dst] = p[src]
	}
	for k, v := range p["post_processing"].(object) {
		if !n(v, 0, 100) {
			return base, errors.New("AI 後製數值超出範圍")
		}
		document[k] = v
	}
	// 暗角和去暗角是同一個有號控制，消去相反的部分。
	vignette := document["vignette"].(float64) - document["devignette"].(float64)
	document["vignette"] = math.Max(0, vignette)
	document["devignette"] = math.Max(0, -vignette)
	for k, v := range p["editor_controls"].(object) {
		document[camel(k)] = v
	}
	result := base
	result.Adjustment, _ = json.Marshal(document)
	if err = l.Validate(result); err != nil {
		return base, fmt.Errorf("AI 配方無效：%w", err)
	}
	return result, nil
}
func camel(value string) string {
	parts := strings.Split(value, "_")
	for i := 1; i < len(parts); i++ {
		parts[i] = strings.ToUpper(parts[i][:1]) + parts[i][1:]
	}
	return strings.Join(parts, "")
}

// 只擷取頂層完整物件；字串中的括號不影響界限。多份結果一律拒絕。
func jsonObjects(text string) []string {
	var result []string
	depth, start := 0, 0
	quoted, escaped := false, false
	for i, ch := range text {
		if escaped {
			escaped = false
			continue
		}
		if quoted && ch == '\\' {
			escaped = true
			continue
		}
		if ch == '"' && depth > 0 {
			quoted = !quoted
			continue
		}
		if quoted {
			continue
		}
		if ch == '{' {
			if depth == 0 {
				start = i
			}
			depth++
		}
		if ch == '}' && depth > 0 {
			depth--
			if depth == 0 {
				result = append(result, text[start:i+1])
			}
		}
	}
	return result
}
