package recipes

import (
	"bytes"
	"encoding/json"
	"reflect"
	"sync"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestLiquifyCacheCloneAndMutableInputIsolation(t *testing.T) {
	lib, err := New()
	if err != nil {
		t.Fatal(err)
	}
	recipe, _ := lib.Default("original")
	data, _ := json.Marshal(liquifyFixture())
	raw := json.RawMessage(data)
	recipe.Liquify = &raw
	if err = lib.Validate(recipe); err != nil {
		t.Fatal(err)
	}
	for _, input := range []json.RawMessage{raw, json.RawMessage(" \n" + string(raw) + "\n"), json.RawMessage(`null`), json.RawMessage(`{`), json.RawMessage(`{"unknown":"<>&"}`)} {
		recipe.Liquify = &input
		want := cloneRecipe(recipe)
		for repeat := 0; repeat < 2; repeat++ {
			got := lib.cloneRecipe(recipe)
			if !reflect.DeepEqual(got, want) {
				t.Fatal("快取 clone 改變序列化語意")
			}
			if got.Liquify != nil {
				before := bytes.Clone(input)
				(*got.Liquify)[0] ^= 1
				if !bytes.Equal(input, before) {
					t.Fatal("clone 與原網格共用可變記憶體")
				}
			}
		}
	}
	recipe.Liquify = &raw
	if err = lib.Validate(recipe); err != nil {
		t.Fatal(err)
	}
	invalid := liquifyFixture()
	invalid.DX[12] = -.49
	raw, _ = json.Marshal(invalid)
	if err = lib.Validate(recipe); err == nil {
		t.Fatal("相同指標內容改變後仍重用舊驗證")
	}
	raw = data
	result, err := lib.Normalize(recipe)
	if err != nil {
		t.Fatal(err)
	}
	(*result.Liquify)[0] = '['
	if err = lib.Validate(recipe); err != nil {
		t.Fatal("呼叫者修改結果破壞來源或驗證快取", err)
	}
	if len(lib.liquifyValidated) > MaxLiquifyBytes || len(lib.liquifyCanonical) > MaxLiquifyBytes {
		t.Fatal("快取超過單份資料大小上限")
	}
}

func TestLiquifyCacheConcurrentValidationAndClone(t *testing.T) {
	lib, err := New()
	if err != nil {
		t.Fatal(err)
	}
	inputs := make([]contract.Recipe, 4)
	for i := range inputs {
		r, _ := lib.Default("original")
		m := liquifyFixture()
		m.DX[12] *= float64(i+1) / 4
		data, _ := json.Marshal(m)
		raw := json.RawMessage(data)
		r.Liquify = &raw
		inputs[i] = r
	}
	var workers sync.WaitGroup
	for _, recipe := range inputs {
		workers.Add(1)
		go func(r contract.Recipe) {
			defer workers.Done()
			for i := 0; i < 20; i++ {
				actual, err := lib.Normalize(r)
				if err != nil || !bytes.Equal(*actual.Liquify, *r.Liquify) {
					t.Error("並行驗證／複製的網格內容不符", err)
					return
				}
				if err = lib.Validate(r); err != nil {
					t.Error(err)
					return
				}
			}
		}(recipe)
	}
	workers.Wait()
}

func TestLiquifyCachedCloneMissingAndInvalidFieldsMatchesPrevious(t *testing.T) {
	lib, err := New()
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(liquifyFixture())
	raw := json.RawMessage(data)
	fields := []json.RawMessage{nil, {}, json.RawMessage("null"), json.RawMessage(`{"text":"<>&"}`), json.RawMessage("{")}
	for _, adjustment := range fields {
		for _, patches := range fields {
			input := contract.Recipe{Version: 1, Style: "original", Adjustment: adjustment, RepairPatches: patches, Liquify: &raw}
			want, got := cloneRecipe(input), lib.cloneRecipe(input)
			if !reflect.DeepEqual(got, want) {
				t.Fatal("nil、缺欄位或無效 JSON 的 clone 回傳值不同")
			}
			if adjustment == nil && patches == nil && (got.Liquify == nil || string(got.Adjustment) != "null") {
				t.Fatal("合法 nil RawMessage 應標準化為 null 並保留網格")
			}
		}
	}
}
