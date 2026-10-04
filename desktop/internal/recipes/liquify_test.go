package recipes

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func liquifyFixture() LiquifyMesh {
	m := LiquifyMesh{Version: 1, ReferenceWidth: 17, ReferenceHeight: 17, Spacing: 4, Columns: 5, Rows: 5, DX: make([]float64, 25), DY: make([]float64, 25)}
	m.DX[12] = -.05
	return m
}

func TestLiquifyValidationAndIdentity(t *testing.T) {
	for _, edit := range []struct {
		name string
		edit func(*LiquifyMesh)
	}{
		{"版本", func(m *LiquifyMesh) { m.Version = 2 }},
		{"最小尺寸", func(m *LiquifyMesh) { m.ReferenceWidth = 1 }},
		{"最大尺寸", func(m *LiquifyMesh) { m.ReferenceHeight = 1025 }},
		{"間距", func(m *LiquifyMesh) { m.Spacing = 1 }},
		{"欄數", func(m *LiquifyMesh) { m.Columns++ }},
		{"列數", func(m *LiquifyMesh) { m.Rows++ }},
		{"位移數量", func(m *LiquifyMesh) { m.DY = m.DY[:24] }},
		{"固定邊界", func(m *LiquifyMesh) { m.DX[0] = .001 }},
		{"超界取樣", func(m *LiquifyMesh) { m.DX[12] = .7 }},
		{"翻折", func(m *LiquifyMesh) { m.DX[12] = -.49 }},
	} {
		t.Run(edit.name, func(t *testing.T) {
			mesh := liquifyFixture()
			edit.edit(&mesh)
			raw, _ := json.Marshal(mesh)
			data := json.RawMessage(raw)
			if _, err := NormalizeLiquify(&data); err == nil {
				t.Fatal("無效網格未被拒絕")
			}
		})
	}
	for _, invalid := range []string{`{}`, `[]`, `{"version":NaN}`, `{"version":1e309}`, `null null`, strings.Repeat(" ", MaxLiquifyBytes+1) + `{}`} {
		raw := json.RawMessage(invalid)
		if _, err := NormalizeLiquify(&raw); err == nil {
			t.Fatal("無效 JSON 或超大網格未被拒絕")
		}
	}
	mesh := liquifyFixture()
	data, _ := json.Marshal(mesh)
	raw := json.RawMessage(data)
	if actual, err := NormalizeLiquify(&raw); err != nil || actual != &raw {
		t.Fatal("合法網格應沿用不可變資料", err)
	}
	mesh.DX[12] = 0
	identity, _ := json.Marshal(mesh)
	for _, input := range []*json.RawMessage{nil, ptrRaw("null"), ptrRaw(string(identity))} {
		if actual, err := NormalizeLiquify(input); err != nil || actual != nil {
			t.Fatal("identity 應正規化為省略網格", err)
		}
	}
	var unknown map[string]any
	_ = json.Unmarshal(data, &unknown)
	unknown["unexpected"] = true
	data, _ = json.Marshal(unknown)
	raw = data
	if _, err := NormalizeLiquify(&raw); err == nil {
		t.Fatal("未知欄位未被拒絕")
	}
}

func ptrRaw(text string) *json.RawMessage { value := json.RawMessage(text); return &value }

func TestLiquifyRecipeNormalizeEditAndClone(t *testing.T) {
	lib, err := New()
	if err != nil {
		t.Fatal(err)
	}
	recipe, _ := lib.Default("original")
	data, _ := json.Marshal(liquifyFixture())
	raw := json.RawMessage(data)
	recipe.Liquify = &raw
	normalized, err := lib.Normalize(recipe)
	if err != nil || normalized.Liquify == nil || !bytes.Equal(*normalized.Liquify, raw) {
		t.Fatal("遷移遺失液化網格", err)
	}
	edited, err := lib.Edit(contract.EditorRequest{Recipe: recipe, Changes: json.RawMessage(`[{"key":"exposure","value":12}]`)})
	if err != nil || edited.Liquify == nil || !bytes.Equal(*edited.Liquify, raw) {
		t.Fatal("一般調整遺失液化網格", err)
	}
	(*edited.Liquify)[0] = '['
	if raw[0] != '{' {
		t.Fatal("可變編輯結果破壞來源網格")
	}
	recipe.Liquify = ptrRaw(`{`)
	if _, err := lib.Normalize(recipe); err == nil {
		t.Fatal("遷移默默捨棄損壞網格")
	}
}
