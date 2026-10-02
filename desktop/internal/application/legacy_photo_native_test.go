package application

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	_ "image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/VaderChen/FilmDevelop/internal/host"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

// 明確啟用才讀取既有照片；所有 Go 紀錄及匯出均寫入隔離目錄，Swift 來源只讀。
func TestLegacyPhotoNativeSmoke(t *testing.T) {
	directory := os.Getenv("FILMDEVELOP_LEGACY_SMOKE_DIRECTORY")
	binary, input := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_ENGINE"), os.Getenv("FILMDEVELOP_NATIVE_SMOKE_IMAGE")
	if directory == "" || binary == "" || input == "" {
		t.Skip("需指定舊照片目錄、原生引擎及預覽照片")
	}
	a := testApp(t)
	root, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	a.legacyPhotoDirectory = filepath.Join(root, "PhotoStyleApp", "PhotoEdits")
	a.services, err = host.New(engine.New(binary))
	if err != nil {
		t.Fatal(err)
	}
	defer a.services.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	a.ctx = ctx
	defer a.workers.Wait()
	a.computing = true
	entries, err := photos.Scan(ctx, directory)
	if err != nil {
		t.Fatal(err)
	}
	edited, err := a.legacyEditedPhotos()
	if err != nil {
		t.Fatal(err)
	}
	indexPath := filepath.Join(a.legacyPhotoDirectory, "edited-photos.json")
	indexBefore, _ := os.ReadFile(indexPath)
	checked, recovered := 0, 0
	for _, entry := range entries.Entries {
		if !edited[entry.ID] {
			continue
		}
		legacyPath := filepath.Join(a.legacyPhotoDirectory, swiftPhotoKey(t, entry.Path)+".json")
		before, err := os.ReadFile(legacyPath)
		if err != nil {
			t.Fatal(err)
		}
		var record struct {
			Selected    string                     `json:"selectedStyle"`
			Adjustments map[string]json.RawMessage `json:"adjustments"`
			Manual      *storage.ManualAdjustments `json:"manualAdjustments"`
			Patches     json.RawMessage            `json:"repairPatches"`
		}
		if err = json.Unmarshal(before, &record); err != nil {
			t.Fatal(err)
		}
		if len(record.Patches) == 0 || string(record.Patches) == "null" {
			record.Patches = json.RawMessage(`[]`)
		}
		fingerprint, err := storage.Fingerprint(ctx, entry.Path)
		if err != nil {
			t.Fatal(err)
		}
		key := storage.PhotoKey(entry.Path, fingerprint)
		if source := os.Getenv("FILMDEVELOP_LEGACY_SMOKE_GO_DATA"); source != "" {
			data, e := os.ReadFile(filepath.Join(source, "photos", key+".json"))
			if e == nil {
				var doc storage.Document
				if e = json.Unmarshal(data, &doc); e != nil {
					t.Fatal(e)
				}
				if !legacyPhotoPlaceholder(&doc) {
					continue // 真正的 Go 編輯由共用回歸測試驗證優先序。
				}
				if e = a.store.Save(key, doc); e != nil {
					t.Fatal(e)
				}
				recovered++
			} else if !os.IsNotExist(e) {
				t.Fatal(e)
			}
		}
		a.organization.Edited[entry.ID] = false
		if err = a.openImage(entry.Path); err != nil {
			t.Fatalf("%s：%v", entry.Name, err)
		}
		expected, err := a.services.NormalizeRecipe(contract.Recipe{Version: 1, Style: record.Selected, Adjustment: record.Adjustments[record.Selected], RepairPatches: record.Patches})
		if err != nil || a.selected != record.Selected || !reflect.DeepEqual(recipeFields(a.recipes[a.selected]), recipeFields(expected)) || !a.organization.Edited[entry.ID] || !reflect.DeepEqual(&a.manual, record.Manual) {
			t.Fatalf("%s 的配方、手動歷史或標記不符：%v", entry.Name, err)
		}
		after, _ := os.ReadFile(legacyPath)
		if !bytes.Equal(before, after) {
			t.Fatal("Swift 原始紀錄被修改")
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("測試目錄沒有可驗證的舊編輯紀錄")
	}
	t.Logf("完整比對 %d 張已編輯照片的配方／歷史／標記，包含 %d 筆空白 Go 紀錄恢復", checked, recovered)
	photoBefore, err := storage.Fingerprint(ctx, input)
	if err != nil {
		t.Fatal(err)
	}
	a.computing = false
	if err = a.OpenImage(input); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.previewError != nil || a.outputPreview == "" || a.outputPreview == a.sourcePreview {
		t.Fatal("還原參數未產生有效且不同於原片的預覽", a.previewError)
	}
	decode := func(value string) []byte {
		parts := strings.SplitN(value, ",", 2)
		if len(parts) != 2 {
			t.Fatal("缺少預覽資料")
		}
		data, err := base64.StdEncoding.DecodeString(parts[1])
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err = image.Decode(bytes.NewReader(data)); err != nil {
			t.Fatal(err)
		}
		return data
	}
	original, restored := decode(a.sourcePreview), decode(a.outputPreview)
	if bytes.Equal(original, restored) {
		t.Fatal("還原預覽未套用調整")
	}
	output := os.Getenv("FILMDEVELOP_LEGACY_SMOKE_OUTPUT")
	if output == "" {
		output = t.TempDir()
	} else if err = os.MkdirAll(output, 0700); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{"original.jpg": original, "restored.jpg": restored} {
		if err = os.WriteFile(filepath.Join(output, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	a.exportSettings.MaxPixel = 1024
	if err = a.ExportImage(filepath.Join(output, "export.png")); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	exported, err := os.ReadFile(filepath.Join(output, "export.png"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = png.Decode(bytes.NewReader(exported)); err != nil || len(exported) < 25 || exported[24] != 16 {
		t.Fatal("還原配方的 16-bit 匯出失敗", err)
	}
	photoAfter, err := storage.Fingerprint(ctx, input)
	indexAfter, _ := os.ReadFile(indexPath)
	if err != nil || photoBefore != photoAfter || !bytes.Equal(indexBefore, indexAfter) {
		t.Fatal("修改了原始照片或 Swift 標記")
	}
	t.Logf("%s：原生預覽及 16-bit PNG 匯出完成，原始照片與 Swift 資料未變更", filepath.Base(input))
}
