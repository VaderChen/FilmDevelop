// Package recipes 提供兩個平台共用的底片目錄、參數編輯與 UI 投影，不呼叫原生程序。
package recipes

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"sort"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

//go:embed catalog.json
var catalogData []byte

//go:embed editor.json
var editorData []byte

//go:embed migration.json
var migrationData []byte

type object = map[string]any
type rule struct {
	Type    string   `json:"type"`
	Minimum float64  `json:"minimum"`
	Maximum float64  `json:"maximum"`
	Enum    []string `json:"enum"`
}

type Library struct {
	catalog           object
	styles            map[string]object
	properties        map[string]rule
	paths             map[string][]string
	manualHDR         object
	migrationDefaults object
	developerDefaults map[string]object
}

func New() (*Library, error) {
	var editor struct {
		Properties map[string]rule     `json:"properties"`
		Paths      map[string][]string `json:"paths"`
		ManualHDR  object              `json:"manualHDRCurve"`
	}
	var catalog object
	var migration struct {
		Defaults          object            `json:"defaults"`
		DeveloperDefaults map[string]object `json:"developerDefaults"`
	}
	if err := json.Unmarshal(catalogData, &catalog); err != nil {
		return nil, err
	}
	if err := json.Unmarshal(editorData, &editor); err != nil {
		return nil, err
	}
	if err := json.Unmarshal(migrationData, &migration); err != nil {
		return nil, err
	}
	lib := &Library{catalog: catalog, styles: map[string]object{}, properties: editor.Properties,
		paths: editor.Paths, manualHDR: editor.ManualHDR, migrationDefaults: migration.Defaults, developerDefaults: migration.DeveloperDefaults}
	entries, ok := catalog["styles"].([]any)
	if !ok || len(entries) == 0 {
		return nil, errors.New("共用底片目錄不完整")
	}
	for _, entry := range entries {
		style, ok := entry.(object)
		if !ok {
			return nil, errors.New("底片項目格式錯誤")
		}
		id, ok := style["id"].(string)
		if !ok || id == "" || lib.styles[id] != nil {
			return nil, errors.New("底片識別格式錯誤或重複")
		}
		lib.styles[id] = style
	}
	if lib.styles["original"] == nil {
		return nil, errors.New("底片目錄缺少原片")
	}
	return lib, nil
}

func clone[T any](value T) T {
	data, _ := json.Marshal(value)
	var result T
	_ = json.Unmarshal(data, &result)
	return result
}

func (l *Library) Default(style string) (contract.Recipe, error) {
	entry, ok := l.styles[style]
	if !ok {
		return contract.Recipe{}, fmt.Errorf("未知底片：%s", style)
	}
	data, err := json.Marshal(entry["adjustment"])
	return contract.Recipe{Version: 1, Style: style, Adjustment: data, RepairPatches: json.RawMessage(`[]`)}, err
}

func (l *Library) Catalog() (json.RawMessage, error) {
	catalog := clone(l.catalog)
	for _, raw := range catalog["styles"].([]any) {
		entry := raw.(object)
		recipe, err := l.Default(entry["id"].(string))
		if err != nil {
			return nil, err
		}
		projection, err := l.Project(recipe)
		if err != nil {
			return nil, err
		}
		entry["uiAdjustment"] = projection
	}
	return json.Marshal(catalog)
}

func get(root object, path []string) (any, bool) {
	var current any = root
	for _, field := range path {
		object, ok := current.(object)
		if !ok {
			return nil, false
		}
		current, ok = object[field]
		if !ok {
			return nil, false
		}
	}
	return current, true
}

func set(root object, path []string, value any) error {
	if len(path) == 0 {
		return errors.New("參數路徑不可為空")
	}
	for _, field := range path[:len(path)-1] {
		next, ok := root[field].(object)
		if !ok {
			return fmt.Errorf("配方缺少欄位：%s", field)
		}
		root = next
	}
	root[path[len(path)-1]] = value
	return nil
}

func emptyTone() object {
	result := object{}
	for _, key := range strings.Fields("base_tone exposure contrast softness grain highlights shadows fade warmth tint mapping") {
		result[key] = float64(0)
	}
	return result
}

func optionalShape(path string) (any, bool) {
	switch path {
	case "adjustment.sourceToneZones":
		return object{"shadows": emptyTone(), "midtones": emptyTone(), "highlights": emptyTone()}, true
	case "adjustment.hdrToneCurve":
		return object{"black": float64(0), "shadows": float64(0), "midtones": float64(0), "highlights": float64(0), "white": float64(0), "detail": float64(0)}, true
	case "adjustment.colorCalibration":
		return object{"version": float64(1), "name": "", "provenance": "", "workingSpace": "", "stage": "", "rows": []any{}}, true
	case "adjustment.filmEffects.print_exposure_highlights", "adjustment.filmEffects.print_exposure_midtones", "adjustment.filmEffects.print_exposure_shadows":
		return float64(0), true
	}
	return nil, false
}

func validateShape(value, sample any, path string) error {
	if reflect.TypeOf(value) != reflect.TypeOf(sample) {
		return fmt.Errorf("配方欄位型別錯誤：%s", path)
	}
	if source, ok := value.(object); ok {
		template := sample.(object)
		for key := range template {
			if _, exists := source[key]; !exists {
				return fmt.Errorf("配方缺少欄位：%s.%s", path, key)
			}
		}
		for key, child := range source {
			expected, exists := template[key]
			if !exists {
				expected, exists = optionalShape(path + "." + key)
			}
			if !exists {
				return fmt.Errorf("配方包含未知欄位：%s.%s", path, key)
			}
			if err := validateShape(child, expected, path+"."+key); err != nil {
				return err
			}
		}
	}
	return nil
}

func (l *Library) checkControl(key string, value any) error {
	rule, exists := l.properties[key]
	if !exists {
		return fmt.Errorf("不支援的調整欄位：%s", key)
	}
	switch rule.Type {
	case "number":
		number, ok := value.(float64)
		if ok && !math.IsNaN(number) && !math.IsInf(number, 0) && number >= rule.Minimum && number <= rule.Maximum {
			return nil
		}
	case "string":
		text, ok := value.(string)
		if ok {
			for _, allowed := range rule.Enum {
				if text == allowed {
					return nil
				}
			}
		}
	case "boolean":
		if _, ok := value.(bool); ok {
			return nil
		}
	}
	return fmt.Errorf("調整欄位的型別或範圍不符：%s", key)
}

func (l *Library) document(recipe contract.Recipe) (object, error) {
	style, ok := l.styles[recipe.Style]
	if !ok || recipe.Version != 1 {
		return nil, errors.New("配方版本或底片識別不符")
	}
	if len(recipe.Adjustment) > contract.MaxMessageBytes || !json.Valid(recipe.RepairPatches) {
		return nil, errors.New("配方資料不完整或超過大小限制")
	}
	var document object
	if err := json.Unmarshal(recipe.Adjustment, &document); err != nil {
		return nil, err
	}
	if document["schemaVersion"] != float64(12) {
		return nil, errors.New("請先遷移舊配方；目前需要 schemaVersion 12")
	}
	if err := validateShape(document, style["adjustment"], "adjustment"); err != nil {
		return nil, err
	}
	for key, path := range l.paths {
		if _, hasRule := l.properties[key]; !hasRule {
			continue
		}
		if value, exists := get(document, path); exists {
			if err := l.checkControl(key, value); err != nil {
				return nil, err
			}
		}
	}
	if err := validateStructured(document); err != nil {
		return nil, err
	}
	return document, nil
}

func (l *Library) Project(recipe contract.Recipe) (object, error) {
	document, err := l.document(recipe)
	if err != nil {
		return nil, err
	}
	result := object{"colorCalibrationName": "", "colorCalibrationStage": ""}
	for key, path := range l.paths {
		value, exists := get(document, path)
		if !exists && strings.HasPrefix(key, "printExposure") {
			value, _ = get(document, l.paths["printExposure"])
		}
		result[key] = value
	}
	if calibration, ok := document["colorCalibration"].(object); ok {
		result["colorCalibrationName"], result["colorCalibrationStage"] = calibration["name"], calibration["stage"]
	}
	if zones, ok := document["sourceToneZones"].(object); ok {
		projected := object{}
		for region, raw := range zones {
			tone := raw.(object)
			fields := object{"baseTone": tone["base_tone"]}
			for _, key := range strings.Fields("contrast softness highlights shadows fade tint") {
				fields[key] = tone[key]
			}
			projected[region] = fields
		}
		result["sourceToneZones"] = projected
	}
	return result, nil
}

func (l *Library) ProjectMany(recipes map[string]contract.Recipe) (map[string]object, error) {
	if len(recipes) > 256 {
		return nil, errors.New("配方數量超過限制")
	}
	result := map[string]object{}
	for id, recipe := range recipes {
		if id != recipe.Style {
			return nil, errors.New("配方底片識別不符")
		}
		projection, err := l.Project(recipe)
		if err != nil {
			return nil, err
		}
		result[id] = projection
	}
	return result, nil
}

func (l *Library) Edit(request contract.EditorRequest) (contract.Recipe, error) {
	result := clone(request.Recipe)
	document, err := l.document(result)
	if err != nil {
		return result, err
	}
	var changes []object
	if len(request.Changes) > contract.MaxMessageBytes {
		return result, errors.New("調整清單超過大小限制")
	}
	if err := json.Unmarshal(request.Changes, &changes); err != nil {
		return result, err
	}
	if len(changes) == 0 || len(changes) > 256 {
		return result, errors.New("調整清單數量不符")
	}
	// 整批先套用印相配方，再依原順序套用個別欄位。
	sort.SliceStable(changes, func(i, j int) bool { return changes[i]["key"] == "printRecipe" && changes[j]["key"] != "printRecipe" })
	originalHDR := clone(document["hdrToneCurve"])
	for _, change := range changes {
		if crop, ok := change["cropValues"].(object); ok {
			if len(crop) == 0 {
				return result, errors.New("裁切欄位不可為空")
			}
			for key, value := range crop {
				path, exists := l.paths[key]
				if !exists || !strings.HasPrefix(key, "crop") {
					return result, fmt.Errorf("裁切欄位不符：%s", key)
				}
				if err := l.checkControl(key, value); err != nil {
					return result, err
				}
				if err := set(document, path, value); err != nil {
					return result, err
				}
			}
			document["imageScoped"] = true
			continue
		}
		key, ok := change["key"].(string)
		if !ok {
			return result, errors.New("調整缺少欄位名稱")
		}
		value, exists := change["value"]
		if !exists {
			return result, errors.New("調整缺少數值")
		}
		if err := l.checkControl(key, value); err != nil {
			return result, err
		}
		switch key {
		case "printExposure":
			l.linkedExposure(document["filmEffects"].(object), value.(float64))
		case "printRecipe":
			if err := l.printRecipe(document, result.Style, value.(string)); err != nil {
				return result, err
			}
		case "vignetteBalance":
			document["vignette"], document["devignette"] = math.Max(0, value.(float64)), math.Max(0, -value.(float64))
		default:
			if region, field, ok := toneField(key); ok {
				zones, ok := document["sourceToneZones"].(object)
				if !ok {
					zones = object{"shadows": emptyTone(), "midtones": emptyTone(), "highlights": emptyTone()}
					document["sourceToneZones"] = zones
				}
				zones[region].(object)[field] = math.Round(value.(float64))
				document["imageScoped"] = true
			} else {
				path, exists := l.paths[key]
				if !exists {
					return result, fmt.Errorf("未知參數路徑：%s", key)
				}
				if err := set(document, path, value); err != nil {
					return result, err
				}
				if strings.HasPrefix(key, "crop") {
					document["imageScoped"] = true
				}
				if key == "hdrAmount" && value.(float64) > 0 && !visibleHDR(originalHDR) {
					document["hdrToneCurve"] = clone(l.manualHDR)
				}
			}
		}
	}
	// 與既有配方相同：暗角與去暗角合併為單一有號數值。
	balance := document["vignette"].(float64) - document["devignette"].(float64)
	document["vignette"], document["devignette"] = math.Max(balance, 0), math.Max(-balance, 0)
	result.DetectSubject = document["backgroundBlur"].(float64) > .001 || math.Abs(document["skinWarmth"].(float64)) > .001 ||
		document["skinWhitening"].(float64) > .001 || document["skinSmoothing"].(float64) > .001
	result.Adjustment, err = json.Marshal(document)
	if err == nil {
		_, err = l.document(result)
	}
	return result, err
}

func toneField(key string) (string, string, bool) {
	for prefix, region := range map[string]string{"highlightPlan": "highlights", "midtonePlan": "midtones", "shadowPlan": "shadows"} {
		if strings.HasPrefix(key, prefix) {
			field := strings.TrimPrefix(key, prefix)
			if field == "BaseTone" {
				return region, "base_tone", true
			}
			if field != "" {
				return region, strings.ToLower(field[:1]) + field[1:], true
			}
		}
	}
	return "", "", false
}

func visibleHDR(value any) bool {
	curve, ok := value.(object)
	if !ok {
		return false
	}
	neutral := object{"black": float64(0), "shadows": float64(25), "midtones": float64(50), "highlights": float64(75), "white": float64(100), "detail": float64(0)}
	return !reflect.DeepEqual(curve, neutral)
}

func (l *Library) linkedExposure(effects object, value float64) {
	base := effects["print_exposure"].(float64)
	fields := []string{"print_exposure", "print_exposure_highlights", "print_exposure_midtones", "print_exposure_shadows"}
	low, high := base, base
	for _, field := range fields[1:] {
		if effects[field] == nil {
			effects[field] = base
		}
		zone := effects[field].(float64)
		low, high = math.Min(low, zone), math.Max(high, zone)
	}
	range_ := l.properties["printExposure"]
	delta := math.Min(range_.Maximum-high, math.Max(range_.Minimum-low, value-base))
	for _, field := range fields {
		effects[field] = effects[field].(float64) + delta
	}
}

func (l *Library) printRecipe(document object, style, selected string) error {
	entry := l.styles[style]
	family, _ := entry["filmFamily"].(string)
	if family == "" || family == "camera" || family == "reversal" {
		return errors.New("此底片不支援印相配方")
	}
	for _, raw := range l.catalog["printRecipes"].([]any) {
		preset := raw.(object)
		if preset["id"] == selected {
			effects := document["filmEffects"].(object)
			effects["scanner_source"] = "paper"
			for _, key := range []string{"paperScatter", "paperWhite", "paperDensityOffset"} {
				if err := set(document, l.paths[key], preset[key]); err != nil {
					return err
				}
			}
			return nil
		}
	}
	return errors.New("未知印相配方")
}

// EditorProperties 與 UI 編輯器使用同一份參數契約，供 MCP 驗證及工具描述。
func (l *Library) EditorProperties() map[string]any {
	data, _ := json.Marshal(l.properties)
	var result map[string]any
	_ = json.Unmarshal(data, &result)
	return result
}
