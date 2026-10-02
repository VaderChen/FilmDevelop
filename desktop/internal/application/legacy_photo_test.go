package application

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

// 固定值由原 Swift 的 sourceImageIdentifier + PhotoEditStore.key 算出，避免測試複製同一個錯誤。
func TestSwiftPhotoIdentity(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("此固定值使用 Swift 在 macOS 的絕對路徑格式")
	}
	const fingerprint = "1c317b2ffdc52d38e708c3a76886f373ad06289f1e117416ac37a871984b5ca0"
	const expected = "ed62afcaa6ff275e7a0923d69ba7608a1af3cfb0587f0c44392adb1da275610c"
	if actual := storage.PhotoKey("/photos/trip/DSC_0001.NEF", "sha256:"+fingerprint); actual != expected {
		t.Fatalf("Swift 照片識別不相容：%s", actual)
	}
}

func swiftPhotoKey(t *testing.T, path string) string {
	t.Helper()
	canonical, err := photos.Canonical(path)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := sha256.Sum256(data)
	digest := sha256.Sum256([]byte(canonical + "\nsha256:" + hex.EncodeToString(fingerprint[:])))
	return hex.EncodeToString(digest[:])
}

func writePhotoJSON(t *testing.T, path string, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err == nil {
		err = os.WriteFile(path, data, 0600)
	}
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func legacyPhotoFixture(t *testing.T) (*App, string, string, contract.Recipe) {
	t.Helper()
	a := testApp(t)
	a.legacyPhotoDirectory = t.TempDir()
	path := filepath.Join(t.TempDir(), "原始照片.nef")
	if err := os.WriteFile(path, []byte("legacy photo fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	path, _ = photos.Canonical(path)
	recipe := a.defaults["filmEktar100"]
	fields := recipeFields(recipe)
	fields["saturation"] = float64(28)
	effects := fields["filmEffects"].(object)
	effects["print_exposure"] = 2.35
	effects["print_exposure_midtones"] = 2.15
	effects["print_contrast"] = float64(69)
	recipe = withFields(recipe, fields)
	legacyPath := filepath.Join(a.legacyPhotoDirectory, swiftPhotoKey(t, path)+".json")
	writePhotoJSON(t, legacyPath, object{"version": 1, "selectedStyle": recipe.Style,
		"adjustments":       map[string]json.RawMessage{recipe.Style: recipe.Adjustment},
		"manualAdjustments": storage.ManualAdjustments{PrintControls: []string{"printExposureMidtones", "printContrast"}, HasCompleteHistory: true}})
	writePhotoJSON(t, filepath.Join(a.legacyPhotoDirectory, "edited-photos.json"), map[string]bool{photos.Identity(path): true})
	return a, path, legacyPath, recipe
}

func TestLegacyPhotoRestoresParametersAndRespectsGoEdits(t *testing.T) {
	for _, name := range []string{"首次讀取", "空白不完整歷史", "空白缺少歷史", "Go 已調整", "Go 明確重設", "Go 已選底片"} {
		t.Run(name, func(t *testing.T) {
			a, path, legacyPath, expected := legacyPhotoFixture(t)
			original, _ := os.ReadFile(legacyPath)
			fingerprint, _ := storage.Fingerprint(a.ctx, path)
			key := storage.PhotoKey(path, fingerprint)
			previous := &storage.Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{}}
			restores := true
			switch name {
			case "首次讀取":
				previous = nil
			case "空白不完整歷史":
				previous.Manual = &storage.ManualAdjustments{PrintControls: []string{}, HasCompleteHistory: false}
			case "Go 已調整":
				expected = a.defaults["original"]
				fields := recipeFields(expected)
				fields["intensity"] = float64(72)
				expected = withFields(expected, fields)
				previous.Recipes["original"] = expected
				restores = false
			case "Go 明確重設":
				previous.Manual = &storage.ManualAdjustments{PrintControls: []string{}, HasCompleteHistory: true}
				expected, restores = a.defaults["original"], false
			case "Go 已選底片":
				previous.Selected = "filmGold200"
				expected, restores = a.defaults["filmGold200"], false
			}
			if previous != nil {
				if err := a.store.Save(key, *previous); err != nil {
					t.Fatal(err)
				}
			}
			// 模擬錯誤版 Go 已把標記清掉，讀取仍須以原始 Swift 紀錄為準。
			a.organization.Edited[photos.Identity(path)] = false
			a.computing = true // 本測試驗證還原及投影；像素另由原生 Smoke 驗證。
			if err := a.openImage(path); err != nil {
				t.Fatal(err)
			}
			if a.selected != expected.Style {
				t.Fatalf("選錯底片：%s，預期 %s", a.selected, expected.Style)
			}
			expected, err := a.services.NormalizeRecipe(expected)
			if err != nil {
				t.Fatal(err)
			}
			actual, err := a.services.NormalizeRecipe(a.recipes[a.selected])
			if err != nil || !reflect.DeepEqual(recipeFields(actual), recipeFields(expected)) {
				t.Fatal("還原配方與已保存參數不符", err)
			}
			projected, _ := a.services.ProjectRecipes(map[string]contract.Recipe{expected.Style: expected})
			if !reflect.DeepEqual(a.ui[a.selected], projected[expected.Style]) {
				t.Fatal("介面未顯示還原參數")
			}
			if restores && (!a.organization.Edited[photos.Identity(path)] || len(a.manual.PrintControls) != 2) {
				t.Fatal("標記或手動調整歷史未恢復")
			}
			_, reopened, err := a.photoDocument(a.ctx, path)
			if err != nil || reopened.Selected != expected.Style {
				t.Fatal("再次開啟遺失調整", err)
			}
			after, _ := os.ReadFile(legacyPath)
			if string(original) != string(after) {
				t.Fatal("修改了原始 Swift 紀錄")
			}
		})
	}
}

func TestLegacyPhotoResetAndDuplicateIsolation(t *testing.T) {
	a, path, legacyPath, _ := legacyPhotoFixture(t)
	fingerprint, _ := storage.Fingerprint(a.ctx, path)
	for _, resetIndex := range []any{map[string]bool{photos.Identity(path): false}, []string{photos.Identity(path)}} {
		writePhotoJSON(t, filepath.Join(a.legacyPhotoDirectory, "edited-photos.json"), resetIndex)
		doc, err := a.legacyPhotoDocument(fingerprint, path)
		_, wasReset := resetIndex.(map[string]bool)
		if err != nil || (doc == nil) != wasReset {
			t.Fatal("Swift 重設標記或舊陣列索引未正確處理", err)
		}
	}
	duplicate := filepath.Join(filepath.Dir(path), "同內容副本.nef")
	data, _ := os.ReadFile(path)
	if err := os.WriteFile(duplicate, data, 0600); err != nil {
		t.Fatal(err)
	}
	_, doc, err := a.photoDocument(a.ctx, duplicate)
	if err != nil || doc.Selected != "original" || len(doc.Recipes) != 0 || !doc.Manual.HasCompleteHistory {
		t.Fatal("同內容副本繼承其他照片的調整", err)
	}
	if err := os.WriteFile(legacyPath, []byte(`{"version":1`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := a.photoDocument(a.ctx, path); err == nil {
		t.Fatal("損壞的紀錄被當成原片")
	}
	if saved, _ := a.store.Load(storage.PhotoKey(path, fingerprint)); saved != nil {
		t.Fatal("損壞紀錄被空白覆蓋")
	}
}

func TestLegacyViewingRecordDoesNotBecomeEdit(t *testing.T) {
	a, path, legacyPath, _ := legacyPhotoFixture(t)
	if err := os.Remove(filepath.Join(a.legacyPhotoDirectory, "edited-photos.json")); err != nil {
		t.Fatal(err)
	}
	for _, scanner := range []string{"neutral", "off"} {
		fields := recipeFields(a.defaults["original"])
		fields["filmEffects"].(object)["scanner_profile"] = scanner
		writePhotoJSON(t, legacyPath, object{"version": 1, "selectedStyle": "original", "adjustments": object{"original": fields}})
		_, doc, err := a.photoDocument(a.ctx, path)
		if err != nil || doc.Selected != "original" || len(doc.Recipes) != 0 || !doc.Manual.HasCompleteHistory {
			t.Fatal("僅瀏覽產生的舊紀錄被視為編輯", err)
		}
	}
}
