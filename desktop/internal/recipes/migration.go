package recipes

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// Normalize 將 schema 1–12 的既有配方移至 schema 12；保留修復貼片與主體遮罩設定。
// 遷移預設取自原 Swift 解碼器，與新建底片的預設分開保存。
func (l *Library) Normalize(recipe contract.Recipe) (contract.Recipe, error) {
	result := cloneRecipe(recipe)
	style, exists := l.styles[recipe.Style]
	if !exists || recipe.Version != 1 || len(recipe.Adjustment) > contract.MaxMessageBytes || !json.Valid(recipe.RepairPatches) {
		return result, errors.New("配方版本、底片或資料格式不符")
	}
	var source object
	if err := json.Unmarshal(recipe.Adjustment, &source); err != nil {
		return result, err
	}
	version := float64(1)
	if raw := source["schemaVersion"]; raw != nil {
		var ok bool
		version, ok = raw.(float64)
		if !ok || version != math.Round(version) || version < 1 || version > 12 {
			return result, errors.New("不支援此配方版本")
		}
	}
	for _, key := range strings.Fields("intensity brightness frameEnabled frameStyle dateEnabled dateStyle") {
		if source[key] == nil {
			return result, fmt.Errorf("舊配方缺少必要欄位：%s", key)
		}
	}
	document := clone(l.migrationDefaults)
	document["filmEffects"].(object)["developer_chemistry"] = clone(l.developerDefaults[recipe.Style])
	if err := mergeLegacy(document, source, "adjustment"); err != nil {
		return result, err
	}
	document["schemaVersion"] = float64(12)
	if version < 2 {
		if source["contrast"] == nil {
			document["contrast"] = float64(0)
		} else {
			document["contrast"] = document["contrast"].(float64) - 50
		}
	}
	grain := document["grain"].(float64)
	for field, factor := range map[string]float64{"highlightGrain": .45, "midtoneGrain": .75, "shadowGrain": 1} {
		if source[field] == nil {
			document[field] = grain * factor
		}
	}
	if source["hdrAmount"] == nil && source["hdrEnabled"] == true {
		document["hdrAmount"] = float64(25)
	}
	delete(document, "hdrEnabled")
	effects := document["filmEffects"].(object)
	if family, _ := style["filmFamily"].(string); version < 10 && family != "" && family != "camera" && family != "reversal" {
		effects["print_exposure"] = -effects["print_exposure"].(float64)
	}
	// 舊引擎識別仍可讀，但新配方只保存現行引擎。
	if !contains([]string{"legacy", "structured", "crystal", "emulsion"}, effects["grain_mode"]) ||
		!contains([]string{"analytic", "spectral"}, effects["color_model"]) {
		return result, errors.New("未知的底片計算模式")
	}
	effects["grain_mode"], effects["color_model"], effects["deep_shadow_amount"] = "emulsion", "spectral", float64(0)
	if !contains(l.properties["frameStyle"].Enum, document["frameStyle"]) {
		document["frameStyle"] = "whitePaperThin"
	}
	for key, path := range l.paths {
		rule, present := l.properties[key]
		value, exists := get(document, path)
		if !present || !exists {
			continue
		}
		if rule.Type == "number" {
			_ = set(document, path, bounded(value.(float64), rule.Minimum, rule.Maximum))
		} else if err := l.checkControl(key, value); err != nil {
			return result, err
		}
	}
	effects["scan_exposure"] = bounded(effects["scan_exposure"].(float64), -4, 4)
	effects["scan_contrast"] = bounded(effects["scan_contrast"].(float64), 0, 100)
	balance := document["vignette"].(float64) - document["devignette"].(float64)
	document["vignette"], document["devignette"] = math.Max(0, balance), math.Max(0, -balance)
	result.Adjustment, _ = json.Marshal(document)
	if len(result.Adjustment) > contract.MaxMessageBytes {
		return result, errors.New("配方資料不完整或超過大小限制")
	}
	return result, l.validateDocument(document, style)
}

func contains(values []string, wanted any) bool {
	for _, value := range values {
		if wanted == value {
			return true
		}
	}
	return false
}

// 僅既有欄位可補預設；未知欄位一律拒絕，避免存檔時默默遺失資料。
func mergeLegacy(target, source object, path string) error {
	for field, value := range source {
		location := path + "." + field
		if location == "adjustment.hdrEnabled" {
			if value != nil {
				if _, ok := value.(bool); !ok {
					return fmt.Errorf("欄位型別不符：%s", location)
				}
			}
			continue
		}
		if location == "adjustment.sourceToneZones" || location == "adjustment.hdrToneCurve" {
			if value == nil {
				continue
			}
			normalized, err := normalizeTones(value, location)
			if err != nil {
				return err
			}
			target[field] = normalized
			continue
		}
		sample, exists := target[field]
		if !exists {
			sample, exists = optionalShape(location)
		}
		if !exists {
			return fmt.Errorf("不支援的配方欄位：%s", location)
		}
		if value == nil {
			if strings.HasPrefix(location, "adjustment.filmEffects.print_exposure_") {
				return fmt.Errorf("曝光分區空值請改為省略欄位：%s", field)
			}
			continue
		}
		if location == "adjustment.colorCalibration" {
			if err := validateShape(value, sample, location); err != nil {
				return err
			}
			target[field] = clone(value)
			continue
		}
		if reflect.TypeOf(value) != reflect.TypeOf(sample) {
			return fmt.Errorf("欄位型別不符：%s", location)
		}
		if child, ok := value.(object); ok {
			if err := mergeLegacy(sample.(object), child, location); err != nil {
				return err
			}
		} else {
			target[field] = value
		}
	}
	return nil
}

func lossyInt(value any, fallback float64) float64 {
	if text, ok := value.(string); ok {
		number, err := strconv.ParseFloat(strings.TrimSpace(text), 64)
		if err != nil {
			return fallback
		}
		value = number
	}
	number, ok := value.(float64)
	if !ok || math.IsNaN(number) || math.IsInf(number, 0) {
		return fallback
	}
	return bounded(math.Round(number), -100, 100)
}

func normalizeTones(value any, path string) (object, error) {
	source, ok := value.(object)
	if !ok {
		return nil, fmt.Errorf("配方欄位需要物件：%s", path)
	}
	if path == "adjustment.sourceToneZones" {
		result := object{"shadows": emptyTone(), "midtones": emptyTone(), "highlights": emptyTone()}
		for region, raw := range source {
			tone, exists := result[region].(object)
			if !exists {
				return nil, fmt.Errorf("未知的明暗分區：%s", region)
			}
			if fields, ok := raw.(object); ok {
				for field, value := range fields {
					if _, exists := tone[field]; !exists {
						return nil, fmt.Errorf("未知的分區參數：%s", field)
					}
					tone[field] = bounded(lossyInt(value, 0), toneMinimum(field), 100)
				}
			}
		}
		return result, nil
	}
	result := object{"black": float64(0), "shadows": float64(25), "midtones": float64(50), "highlights": float64(75), "white": float64(100), "detail": float64(0)}
	for field, value := range source {
		fallback, exists := result[field].(float64)
		if !exists {
			return nil, fmt.Errorf("未知的 HDR 參數：%s", field)
		}
		result[field] = lossyInt(value, fallback)
	}
	previous := float64(0)
	for _, field := range strings.Fields("black shadows midtones highlights white") {
		previous = bounded(result[field].(float64), previous, 100)
		result[field] = previous
	}
	result["detail"] = bounded(result["detail"].(float64), 0, 40)
	return result, nil
}
