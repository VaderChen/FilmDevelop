package application

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestCustomDefaultsTracksRecipeChanges(t *testing.T) {
	a := testApp(t)
	r := a.recipes["filmPortra400"]
	a.customFilms = []CustomFilm{{ID: "custom-cache", Name: "預設底片", BaseStyle: r.Style, Adjustment: append(json.RawMessage{}, r.Adjustment...)}}
	a.selectedCustom = a.customFilms[0].ID
	verify := func() {
		t.Helper()
		wantRecipe, err := a.services.NormalizeRecipe(filmRecipe(a.customFilms[0]))
		if err != nil {
			t.Fatal(err)
		}
		want, err := a.services.ProjectRecipes(map[string]contract.Recipe{wantRecipe.Style: wantRecipe})
		if err != nil || !reflect.DeepEqual(a.currentDefaults(), want[wantRecipe.Style]) {
			t.Fatal("自訂預設與重新投影結果不符", err)
		}
	}
	verify()
	verify()
	// 同 ID、同長度、共用底層切片的修改也必須使快取失效。
	var document object
	if err := json.Unmarshal(a.customFilms[0].Adjustment, &document); err != nil {
		t.Fatal(err)
	}
	document["contrast"] = float64(12)
	changed, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	a.customFilms[0].Adjustment = changed
	verify()
	i := bytes.Index(changed, []byte(`"contrast":12,`))
	if i < 0 {
		t.Fatal("缺少原地修改所需的配方欄位")
	}
	changed[i+len(`"contrast":1`)] = '3'
	verify()
	a.customFilms[0].Name = "重新命名"
	verify()
	other := a.recipes["filmClassicChrome"]
	if other.Style == "" {
		other = a.recipes["original"]
	}
	a.customFilms[0].BaseStyle, a.customFilms[0].Adjustment = other.Style, other.Adjustment
	verify()
	// 發布快照不能將快取中的可變容器交給前端。
	published := false
	a.emit = func(event string, payload any) {
		if event == "handleNativeState" {
			payload.(object)["adjustmentDefaults"].(object)["contrast"] = float64(99)
			published = true
		}
	}
	a.sendState(false)
	if !published {
		t.Fatal("未發布狀態快照")
	}
	verify()
	a.customFilms = nil
	if !reflect.DeepEqual(a.currentDefaults(), a.defaultUI[a.selected]) || a.customDefaults != nil {
		t.Fatal("刪除底片未回復內建預設")
	}
	// 損毀配方不保留舊快取，並維持內建預設的回退流程。
	a.customFilms = []CustomFilm{{ID: a.selectedCustom, BaseStyle: r.Style, Adjustment: json.RawMessage(`{}`)}}
	if !reflect.DeepEqual(a.currentDefaults(), a.defaultUI[a.selected]) || a.customDefaults != nil {
		t.Fatal("損毀底片未回復內建預設")
	}
}
