package recipes

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestGeneratedPlanContract(t *testing.T) {
	l, err := New()
	if err != nil {
		t.Fatal(err)
	}
	base, _ := l.Default("filmGold200")
	var p object
	_ = json.Unmarshal(planTemplate, &p)
	p["strength"] = float64(37)
	p["tone_zones"].(object)["midtones"].(object)["exposure"] = float64(-20)
	p["film_effects"].(object)["print_exposure_highlights"] = 2.375
	p["editor_controls"].(object)["crop_rotation"] = 3.5
	encode := func(p object) string { data, _ := json.Marshal(p); return string(data) }
	valid := encode(p)
	result, err := l.MapPlan("```json\n"+valid+"\n```", base)
	if err != nil {
		t.Fatal(err)
	}
	var fields object
	_ = json.Unmarshal(result.Adjustment, &fields)
	if fields["intensity"] != float64(37) || fields["midtoneExposure"] != float64(-20) || fields["cropRotation"] != 3.5 || fields["filmEffects"].(object)["print_exposure_highlights"] != 2.375 {
		t.Fatal("模型明確值未保留")
	}
	for _, bad := range []string{valid + valid, strings.Replace(valid, `"strength":37`, `"strength":true`, 1), strings.Replace(valid, `"grain":0`, `"grain":-1`, 1), strings.Replace(valid, `"crop_rotation":3.5`, `"crop_rotation":99`, 1)} {
		if _, err = l.MapPlan(bad, base); err == nil {
			t.Fatal("接受無效或多份配方")
		}
	}
	delete(p["editor_controls"].(object), "crop_rotation")
	if _, err = l.MapPlan(encode(p), base); err == nil {
		t.Fatal("接受不完整編輯控制")
	}
}
