package storage

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestPhotoLiquifyStoredOnceAndSharedAfterLoad(t *testing.T) {
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	store, err := New()
	if err != nil {
		t.Fatal(err)
	}
	mesh := json.RawMessage(`{"marker":"` + strings.Repeat("L", 1024*1024) + `"}`)
	doc := Document{Version: 1, Selected: "style0", Recipes: map[string]contract.Recipe{}}
	for i := 0; i < 37; i++ {
		id := fmt.Sprintf("style%d", i)
		doc.Recipes[id] = contract.Recipe{Version: 1, Style: id, Adjustment: json.RawMessage(`{}`), RepairPatches: json.RawMessage(`[]`), Liquify: &mesh}
	}
	key := strings.Repeat("b", 64)
	if err = store.Save(key, doc); err != nil {
		t.Fatal(err)
	}
	path, _ := store.path(key)
	data, err := os.ReadFile(path)
	if err != nil || bytes.Count(data, []byte(`"marker"`)) != 1 || len(data) > 2*1024*1024 {
		t.Fatal("同照片網格被重複保存", err)
	}
	loaded, err := store.Load(key)
	if err != nil || loaded.SharedLiquify != nil {
		t.Fatal("無法展開共用網格", err)
	}
	first := loaded.Recipes["style0"].Liquify
	for id, recipe := range loaded.Recipes {
		if recipe.Liquify == nil || recipe.Liquify != first {
			t.Fatal("已讀網格未共用同一份不可變記憶體", id)
		}
		if doc.Recipes[id].Liquify != &mesh {
			t.Fatal("儲存時修改呼叫方的照片紀錄")
		}
	}
	var actual, expected any
	_ = json.Unmarshal(*first, &actual)
	_ = json.Unmarshal(mesh, &expected)
	if fmt.Sprint(actual) != fmt.Sprint(expected) {
		t.Fatal("液化內容在存讀後改變")
	}
	var conflict map[string]any
	_ = json.Unmarshal(data, &conflict)
	conflict["recipes"].(map[string]any)["style0"].(map[string]any)["liquify"] = map[string]any{"other": true}
	data, _ = json.Marshal(conflict)
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = store.Load(key); err == nil {
		t.Fatal("共用網格與底片的衝突未被拒絕")
	}
}
