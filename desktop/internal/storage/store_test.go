package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/VaderChen/FilmDevelop/internal/contract"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestPortableIdentityAndRecordProtection(t *testing.T) {
	root := t.TempDir()
	t.Setenv("FILMDEVELOP_DATA_DIR", filepath.Join(root, "資料"))
	a, b := filepath.Join(root, "原圖.png"), filepath.Join(root, "另一個名稱.png")
	for _, path := range []string{a, b} {
		if err := os.WriteFile(path, []byte("相同照片內容"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	key, err := Fingerprint(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	other, err := Fingerprint(context.Background(), b)
	if err != nil || key != other {
		t.Fatal("搬動或改名後識別碼改變")
	}
	s, _ := New()
	document := Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{"original": {Version: 1, Style: "original", Adjustment: json.RawMessage(`{"schemaVersion":12,"exposure":12}`), RepairPatches: json.RawMessage(`[]`)}}}
	if err := s.Save(key, document); err != nil {
		t.Fatal(err)
	}
	loaded, err := s.Load(other)
	if err != nil || loaded.Selected != "original" {
		t.Fatal(err)
	}
	path, _ := s.path(key)
	future := []byte(`{"version":99,"selected":"original","recipes":{}}`)
	if err := os.WriteFile(path, future, 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(key, document); err == nil {
		t.Fatal("覆蓋未知版本的紀錄")
	}
	data, _ := os.ReadFile(path)
	if string(data) != string(future) {
		t.Fatal("原紀錄遭到變更")
	}
}

func TestPhotoRepairPayloadStoredOnce(t *testing.T) {
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	store, err := New()
	if err != nil {
		t.Fatal(err)
	}
	patch := json.RawMessage(`[{"id":"shared","imageData":"` + strings.Repeat("A", 1024*1024) + `"}]`)
	document := Document{Version: 1, Selected: "style0", Recipes: map[string]contract.Recipe{}}
	for i := 0; i < 37; i++ {
		id := fmt.Sprintf("style%d", i)
		document.Recipes[id] = contract.Recipe{Version: 1, Style: id, Adjustment: json.RawMessage(`{}`), RepairPatches: patch}
	}
	key := strings.Repeat("a", 64)
	if err = store.Save(key, document); err != nil {
		t.Fatal(err)
	}
	path, _ := store.path(key)
	info, err := os.Stat(path)
	if err != nil || info.Size() > 2*1024*1024 {
		t.Fatal("補片重複保存")
	}
	loaded, err := store.Load(key)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range loaded.Recipes {
		var actual, expected any
		_ = json.Unmarshal(r.RepairPatches, &actual)
		_ = json.Unmarshal(patch, &expected)
		if !reflect.DeepEqual(actual, expected) {
			t.Fatal("修復紀錄遺失")
		}
	}
}
