package application

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/photos"
)

func legacyOrganizationFixture(t *testing.T) (*App, string, organization) {
	t.Helper()
	a := testApp(t)
	root := t.TempDir()
	a.legacyPhotoDirectory = filepath.Join(root, "PhotoEdits")
	if err := os.Mkdir(a.legacyPhotoDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	legacy := organization{Version: 1, Tags: []string{"旅行", "人像", "未使用"}, Photos: map[string]photoMetadata{
		photos.Identity("/one.nef"): {Rating: 5, Tags: []string{"旅行"}},
		photos.Identity("/two.nef"): {Rating: 3, Tags: []string{"人像"}},
	}}
	path := filepath.Join(root, "PhotoOrganization.json")
	writePhotoJSON(t, path, legacy)
	writePhotoJSON(t, filepath.Join(a.legacyPhotoDirectory, "edited-photos.json"), map[string]bool{"old-edit": true})
	return a, path, legacy
}

func TestOrganizationMigrationPreservesGoChanges(t *testing.T) {
	for _, mode := range []string{"首次使用", "僅有編輯標記", "已有分類分級", "明確清除"} {
		t.Run(mode, func(t *testing.T) {
			a, legacyPath, legacy := legacyOrganizationFixture(t)
			before, _ := os.ReadFile(legacyPath)
			key := photos.Identity("/one.nef")
			previous := clone(a.organization)
			previous.Edited = map[string]bool{"go-edit": true}
			previous.Edited["old-edit"] = false
			if mode == "已有分類分級" {
				previous.Tags = []string{"Go 分類"}
				previous.Photos[key] = photoMetadata{Rating: 2, Tags: []string{"Go 分類"}}
			} else if mode == "明確清除" {
				previous.Photos[key] = photoMetadata{Tags: []string{}}
			}
			if mode != "首次使用" {
				if err := a.store.SaveState("organization.json", previous); err != nil {
					t.Fatal(err)
				}
			}
			if err := a.loadOrganization(); err != nil {
				t.Fatal(err)
			}
			for id, expected := range legacy.Photos {
				if override, exists := previous.Photos[id]; exists {
					expected = override
				}
				if !reflect.DeepEqual(a.organization.Photos[id], expected) {
					t.Fatal("舊紀錄未補入或覆蓋 Go 變更", id)
				}
			}
			if !a.organization.LegacyOrganizationImported {
				t.Fatal("未保存遷移狀態")
			}
			if mode == "首次使用" {
				if !a.organization.Edited["old-edit"] {
					t.Fatal("首次遷移遺失編輯標記")
				}
			} else if !reflect.DeepEqual(a.organization.Edited, previous.Edited) {
				t.Fatal("分類遷移覆蓋既有編輯標記")
			}
			if !contains(a.organization.Tags, "未使用") {
				t.Fatal("遺失未使用的分類定義")
			}
			saved := clone(a.organization)
			if err := a.loadOrganization(); err != nil || !reflect.DeepEqual(a.organization, saved) {
				t.Fatal("重新載入不一致", err)
			}
			// 即使原 Swift 來源之後損壞，已完成遷移的 Go 資料仍可獨立使用。
			if err := a.changeMetadata([]string{"/two.nef"}, "clear", nil); err != nil {
				t.Fatal(err)
			}
			if err := a.changeMetadata([]string{"/two.nef"}, "rating", 0); err != nil {
				t.Fatal(err)
			}
			if err := a.changeMetadata(nil, "remove", "人像"); err != nil {
				t.Fatal(err)
			}
			if after, _ := os.ReadFile(legacyPath); !bytes.Equal(before, after) {
				t.Fatal("更動原始 Swift 分類檔案")
			}
			if err := os.WriteFile(legacyPath, []byte("broken"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := a.loadOrganization(); err != nil {
				t.Fatal(err)
			}
			if metadata := a.organization.Photos[photos.Identity("/two.nef")]; metadata.Rating != 0 || len(metadata.Tags) != 0 || contains(a.organization.Tags, "人像") {
				t.Fatal("重新匯入已清除的分級或分類")
			}
		})
	}
}

func TestOrganizationMigrationRejectsDamagedSourceAtomically(t *testing.T) {
	for _, damage := range []string{"JSON", "版本", "分級", "重複分類", "不存在的分類", "重複照片分類", "欄位缺漏", "保存失敗"} {
		t.Run(damage, func(t *testing.T) {
			a, path, legacy := legacyOrganizationFixture(t)
			statePath := filepath.Join(os.Getenv("FILMDEVELOP_DATA_DIR"), "state", "organization.json")
			if err := a.store.SaveState("organization.json", a.organization); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(statePath)
			visible := a.organization
			switch damage {
			case "JSON":
				_ = os.WriteFile(path, []byte(`{"version":`), 0600)
			case "版本":
				legacy.Version = 9
			case "分級":
				legacy.Photos["bad"] = photoMetadata{Rating: 6}
			case "重複分類":
				legacy.Tags = append(legacy.Tags, "旅行")
			case "不存在的分類":
				legacy.Photos["bad"] = photoMetadata{Tags: []string{"不存在"}}
			case "重複照片分類":
				legacy.Photos["bad"] = photoMetadata{Tags: []string{"旅行", "旅行"}}
			case "欄位缺漏":
				_ = os.WriteFile(path, []byte(`{"version":1}`), 0600)
			case "保存失敗":
				// POSIX 目錄唯讀會讓原子暫存檔建立失敗。
				if runtime.GOOS == "windows" {
					t.Skip("Windows 的唯讀屬性不限制建立子檔案")
				}
				if err := os.Chmod(filepath.Dir(statePath), 0500); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.Chmod(filepath.Dir(statePath), 0700) })
			}
			if damage != "JSON" && damage != "欄位缺漏" {
				writePhotoJSON(t, path, legacy)
			}
			if err := a.loadOrganization(); err == nil {
				t.Fatal("應拒絕損壞來源或寫入失敗")
			}
			if after, _ := os.ReadFile(statePath); !bytes.Equal(before, after) {
				t.Fatal("失敗仍覆蓋 Go 資料")
			}
			if !reflect.DeepEqual(a.organization, visible) {
				t.Fatal("失敗仍替換記憶體狀態")
			}
		})
	}
}

func TestOrganizationMigrationRetriesWhenSourceAppears(t *testing.T) {
	a, path, _ := legacyOrganizationFixture(t)
	data, _ := os.ReadFile(path)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := a.loadOrganization(); err != nil || a.organization.LegacyOrganizationImported {
		t.Fatal("缺少來源仍標記完成", err)
	}
	a.source = "/one.nef"
	if err := a.markEdited(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.loadOrganization(); err != nil || len(a.organization.Photos) != 2 {
		t.Fatal("來源出現後未重試", err)
	}
}
