package recipes

import (
	"errors"
	"fmt"
	"math"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/rivo/uniseg"
)

// Validate 接受完整的現行配方；舊資料須明確經過 Normalize，不能在渲染時靜默補值。
func (l *Library) Validate(recipe contract.Recipe) error {
	_, err := l.document(recipe)
	return err
}

func bounded(value, low, high float64) float64 { return math.Min(high, math.Max(low, value)) }

func toneMinimum(key string) float64 {
	switch key {
	case "softness", "grain", "fade", "mapping":
		return 0
	default:
		return -100
	}
}

func validateStructured(document object) error {
	if document["vignette"].(float64) > 0 && document["devignette"].(float64) > 0 {
		return errors.New("暗角與去暗角須先合併")
	}
	effects := document["filmEffects"].(object)
	for key, limits := range map[string][2]float64{"scan_exposure": {-4, 4}, "scan_contrast": {0, 100}, "deep_shadow_amount": {0, 0}} {
		value := effects[key].(float64)
		if value < limits[0] || value > limits[1] {
			return fmt.Errorf("配方參數超出範圍：%s", key)
		}
	}
	if zones, ok := document["sourceToneZones"].(object); ok {
		for _, raw := range zones {
			for field, value := range raw.(object) {
				n := value.(float64)
				if n != math.Round(n) || n < toneMinimum(field) || n > 100 {
					return fmt.Errorf("分區參數不是有效整數：%s", field)
				}
			}
		}
	}
	if curve, ok := document["hdrToneCurve"].(object); ok {
		previous := float64(0)
		for _, field := range strings.Fields("black shadows midtones highlights white") {
			n := curve[field].(float64)
			if n != math.Round(n) || n < previous || n > 100 {
				return errors.New("HDR 曲線必須依序遞增且介於 0 至 100")
			}
			previous = n
		}
		n := curve["detail"].(float64)
		if n != math.Round(n) || n < 0 || n > 40 {
			return errors.New("HDR 細節必須是 0 至 40 的整數")
		}
	}
	if calibration, ok := document["colorCalibration"].(object); ok {
		return validateCalibration(calibration)
	}
	return nil
}

func validateCalibration(value object) error {
	valid := value["version"] == float64(1) && value["workingSpace"] == "extendedLinearSRGB" &&
		(value["stage"] == "input" || value["stage"] == "output")
	for field, maximum := range map[string]int{"name": 160, "provenance": 4000} {
		text := value[field].(string)
		valid = valid && strings.TrimSpace(text) != "" && uniseg.GraphemeClusterCount(text) <= maximum
	}
	rows := value["rows"].([]any)
	valid = valid && len(rows) == 3
	for _, raw := range rows {
		row, ok := raw.([]any)
		valid = valid && ok && len(row) == 6
		for _, raw := range row {
			n, ok := raw.(float64)
			valid = valid && ok && !math.IsNaN(n) && !math.IsInf(n, 0) && math.Abs(n) <= 16
		}
	}
	if !valid {
		return errors.New("校準檔必須包含線性 sRGB 工作空間、來源、套用階段及有效的 3×6 係數")
	}
	return nil
}
