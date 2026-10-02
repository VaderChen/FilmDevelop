package application

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

func testApp(t *testing.T) *App {
	t.Helper()
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	a, err := New("unused-engine")
	if err != nil {
		t.Fatal(err)
	}
	a.ctx = context.Background()
	a.emit = func(string, any) {}
	close(a.ready)
	if err = a.loadCatalog(); err != nil {
		t.Fatal(err)
	}
	if err = a.loadUserLibrary(); err != nil {
		t.Fatal(err)
	}
	if err = a.loadOrganization(); err != nil {
		t.Fatal(err)
	}
	return a
}
func TestPhotoGeometryAndCompleteUndo(t *testing.T) {
	a := testApp(t)
	a.source = "fixture.png"
	if err := a.update(object{"adjustments": []any{object{"key": "cropAspectRatio", "value": "free"}, object{"key": "cropWidth", "value": float64(70)}, object{"key": "exposure", "value": float64(12)}}}); err != nil {
		t.Fatal(err)
	}
	before := a.snapshot()
	if err := a.selectStyle("filmPortra400"); err != nil {
		t.Fatal(err)
	}
	if a.ui[a.selected]["cropWidth"] != float64(70) {
		t.Fatal("切換底片遺失共用裁切")
	}
	if err := a.restore(a.undo[len(a.undo)-1]); err != nil {
		t.Fatal(err)
	}
	actual, _ := json.Marshal(a.snapshot())
	expected, _ := json.Marshal(before)
	if string(actual) != string(expected) {
		t.Fatal("復原未恢復整次交易")
	}
}
func TestCustomFilmTransferHasNoPhotoGeometry(t *testing.T) {
	a := testApp(t)
	if err := a.update(object{"key": "cropWidth", "value": float64(70)}); err != nil {
		t.Fatal(err)
	}
	if err := a.saveFilm("測試底片", a.recipes["original"], ""); err != nil {
		t.Fatal(err)
	}
	f := a.customFilms[0]
	var fields object
	_ = json.Unmarshal(f.Adjustment, &fields)
	if fields["cropWidth"] != nil {
		t.Fatal("自訂底片不應保存照片裁切")
	}
	if err := a.selectStyle(f.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := a.services.NormalizeRecipe(a.recipes[a.selected]); err != nil {
		t.Fatal(err)
	}
	if a.ui[a.selected]["cropWidth"] != float64(70) {
		t.Fatal("選自訂底片遺失當前裁切")
	}
	if err := a.selectStyle("original"); err != nil {
		t.Fatal(err)
	}
	if a.selectedCustom != "" || a.customBase != nil {
		t.Fatal("自訂底片未解除")
	}
	if err := a.saveFilm("測試底片", a.recipes["original"], ""); err == nil {
		t.Fatal("重名底片應拒絕")
	}
}
func TestPersistentRenderingPreferences(t *testing.T) {
	a := testApp(t)
	for _, key := range []string{"setHDRFeatureEnabled", "setHighlightProtectionEnabled", "setLensCorrectionEnabled"} {
		if err := a.setPreference(key, object{"enabled": false}); err != nil {
			t.Fatal(err)
		}
	}
	if err := a.setPreference("setOriginalResolutionEditing", object{"enabled": true}); err != nil {
		t.Fatal(err)
	}
	b, err := New("unused-engine")
	if err != nil {
		t.Fatal(err)
	}
	job := b.job("", a.defaults["original"], true)
	if job.Input.LensCorrection || job.Policy.Hdr || job.Policy.HighlightProtection || !job.Policy.FullResolution {
		t.Fatal("重啟後設定未傳入原生渲染工作")
	}
}

func TestMissingNativeEnginePreservesSharedOperations(t *testing.T) {
	a := testApp(t)
	if err := a.loadCapabilities(); err == nil {
		t.Fatal("不存在的原生引擎不得回報可用")
	}
	if a.capabilities["available"] != false || a.capabilities["mlx"] != false {
		t.Fatal("平台能力應如實回報不可用")
	}
	if err := a.handle(object{"action": "setStyle", "style": "filmGold200"}); err != nil {
		t.Fatal("共用配方不應被硬體缺失阻擋", err)
	}
	if err := a.setPreference("setShowAllFilms", object{"enabled": true}); err != nil {
		t.Fatal(err)
	}
	if err := a.loadModels(); err != nil || a.repository.Format != "gguf" {
		t.Fatal("不支援 MLX 的平台應提供 GGUF 搜尋", err)
	}
	if a.selected != "filmGold200" || !a.preferences.ShowAllFilms {
		t.Fatal("Go 共用操作未生效")
	}
}

func TestInitialUILanguageDoesNotOverwriteSavedPreference(t *testing.T) {
	a := testApp(t)
	a.preferences.Language = "japanese"
	if err := a.setPreference("setLanguage", object{"initial": true, "preference": "automatic", "systemLanguage": "english"}); err != nil {
		t.Fatal(err)
	}
	if a.preferences.Language != "japanese" || a.effectivePromptLanguage() != "japanese" {
		t.Fatal("初次載入畫面覆蓋了已保存的語言")
	}
	if err := a.setPreference("setLanguage", object{"preference": "automatic"}); err != nil {
		t.Fatal(err)
	}
	if a.effectivePromptLanguage() != "english" {
		t.Fatal("自動語言未跟隨系統")
	}
}
func TestSameContentPhotosRemainIndependent(t *testing.T) {
	a := testApp(t)
	dir := t.TempDir()
	p1, p2 := filepath.Join(dir, "原圖.png"), filepath.Join(dir, "副本.png")
	for _, p := range []string{p1, p2} {
		if err := os.WriteFile(p, []byte("same content"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	hash, err := storage.Fingerprint(a.ctx, p1)
	if err != nil {
		t.Fatal(err)
	}
	old := storage.Document{Version: 1, Selected: "filmPortra400", Recipes: map[string]contract.Recipe{"filmPortra400": a.defaults["filmPortra400"]}}
	if err = a.store.Save(hash, old); err != nil {
		t.Fatal(err)
	}
	key, doc, err := a.photoDocument(a.ctx, p1)
	if err != nil || doc.Selected != "filmPortra400" {
		t.Fatal("既有 Go 紀錄未遷移", err)
	}
	if err = a.store.Save(key, *doc); err != nil {
		t.Fatal(err)
	}
	key2, _, err := a.photoDocument(a.ctx, p2)
	if err != nil || key == key2 {
		t.Fatal("複本識別未隔離", err)
	}
}
func TestPhotoTagsAndMetadata(t *testing.T) {
	a := testApp(t)
	paths := []string{"/照片/1.jpg", "/照片/2.jpg"}
	if err := a.changeMetadata(paths, "tag", "旅行"); err != nil {
		t.Fatal(err)
	}
	if err := a.changeMetadata(nil, "remove", "旅行"); err == nil {
		t.Fatal("不得移除仍使用中的分類")
	}
	if err := a.changeMetadata(paths, "clear", nil); err != nil {
		t.Fatal(err)
	}
	if err := a.changeMetadata(nil, "remove", "旅行"); err != nil {
		t.Fatal(err)
	}
	groups := metadataGroups(object{"PixelWidth": float64(97), "PixelHeight": float64(65), "{Exif}": object{"ExposureTime": 1.0 / 125, "FNumber": 2.8}, "{TIFF}": object{"Make": "Camera"}})
	if len(groups) != 3 {
		t.Fatalf("EXIF 分組不符：%v", groups)
	}
}

func TestBatchApplyPreservesTargetRepairAndIndependentRecords(t *testing.T) {
	a := testApp(t)
	folder := t.TempDir()
	first := filepath.Join(folder, "a.png")
	second := filepath.Join(folder, "b.png")
	if err := os.WriteFile(first, []byte("source fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte("target fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	firstKey, doc, err := a.photoDocument(a.ctx, first)
	if err != nil {
		t.Fatal(err)
	}
	if err = a.store.Save(firstKey, *doc); err != nil {
		t.Fatal(err)
	}
	secondKey, doc, err := a.photoDocument(a.ctx, second)
	if err != nil {
		t.Fatal(err)
	}
	patch := json.RawMessage(`[{"id":"target-repair","imageData":"AA==","maskData":"AA=="}]`)
	recipe := a.defaults["original"]
	recipe.RepairPatches = patch
	doc.Recipes["original"] = recipe
	if err = a.store.Save(secondKey, *doc); err != nil {
		t.Fatal(err)
	}
	if err = a.batchPhotos([]string{first}, "copy", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if err = a.batchPhotos([]string{second}, "apply", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	result, err := a.store.Load(secondKey)
	if err != nil {
		t.Fatal(err)
	}
	if result.Selected != "original" || !strings.Contains(string(result.Recipes["original"].RepairPatches), "target-repair") {
		t.Fatal("套用原片遺失目標修復")
	}
	if err = a.batchPhotos([]string{second}, "duplicate", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	files, err := os.ReadDir(folder)
	if err != nil || len(files) != 3 {
		t.Fatal("複製照片失敗", err, files)
	}
	original, err := a.store.Load(firstKey)
	if err != nil || len(original.Recipes) != 0 {
		t.Fatal("来源紀錄受到修改")
	}
}
