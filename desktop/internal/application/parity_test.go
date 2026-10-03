package application

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
	"github.com/VaderChen/FilmDevelop/internal/models"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

// 以 Swift 既有操作語意驗證配方、狀態、儲存及匯出工作。
func restoredParityRecord(t *testing.T, id string, expected, actual any) {
	t.Helper()
	data, err := json.Marshal(object{"id": id, "swift": expected, "go": actual})
	if err != nil {
		t.Fatal(err)
	}
	t.Log("PARITY " + string(data))
}

func restoredParityApp(t *testing.T) (*App, string) {
	t.Helper()
	a := testApp(t)
	var data bytes.Buffer
	if err := jpeg.Encode(&data, image.NewRGBA(image.Rect(0, 0, 4, 3)), nil); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "來源.jpg")
	if err := os.WriteFile(path, data.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	path, err := photos.Canonical(path)
	if err != nil {
		t.Fatal(err)
	}
	directory, err := photos.Scan(context.Background(), filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	a.installDirectory(directory)
	fingerprint, err := storage.Fingerprint(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	a.source, a.imageKey = path, storage.PhotoKey(path, fingerprint)
	a.sourceIdentity = &storage.PhotoSource{Path: path, Fingerprint: fingerprint}
	a.sourceWidth, a.sourceHeight = 4, 3
	backend := previewBackend{
		thumbnail: func(context.Context, string) ([]byte, error) { return data.Bytes(), nil },
		render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
			return json.RawMessage(`{"sourceWidth":4,"sourceHeight":3,"cropWidth":4,"cropHeight":3,"outputWidth":4,"outputHeight":3}`), os.WriteFile(job.Output.Path, data.Bytes(), 0600)
		},
	}
	a.services, err = host.New(backend)
	if err != nil {
		t.Fatal(err)
	}
	a.thumbnailServices, err = host.New(backend)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.workers.Wait)
	return a, path
}

func TestSwiftParityCustomFilmBase(t *testing.T) {
	a := testApp(t)
	style := "filmPortra400"
	a.selected = style
	base := a.defaults[style]
	fields := recipeFields(base)
	fields["contrast"] = float64(73)
	if err := a.saveFilm("稽核用底片", withFields(base, fields), ""); err != nil {
		t.Fatal(err)
	}
	if err := a.selectStyle(a.customFilms[0].ID); err != nil {
		t.Fatal(err)
	}
	if err := a.selectStyle(style); err != nil {
		t.Fatal(err)
	}
	actual := recipeFields(a.recipes[style])["contrast"]
	expected := recipeFields(base)["contrast"]
	if actual != expected {
		t.Fatal("未修復自訂底片覆蓋原底片", actual, expected)
	}
	restoredParityRecord(t, "F01", object{"contrast": expected, "customID": ""}, object{"contrast": actual, "customID": a.selectedCustom})
}

func TestSwiftParityStyleExposureHDR(t *testing.T) {
	a := testApp(t)
	a.modelEntries = []models.Entry{{ID: "稽核模型", Format: "gguf", Ready: true}}
	a.modelSettings = modelSettings{Enabled: true, Selected: "稽核模型"}
	if _, ok := a.activeModel(); !ok {
		t.Fatal("AI 前提未建立")
	}
	fields := recipeFields(a.recipes[a.selected])
	fields["exposure"], fields["hdrAmount"] = float64(12), float64(45)
	a.recipes[a.selected] = withFields(a.recipes[a.selected], fields)
	if err := a.selectStyle("filmPortra400"); err != nil {
		t.Fatal(err)
	}
	actual := recipeFields(a.recipes[a.selected])
	if actual["exposure"] != float64(12) || actual["hdrAmount"] != float64(45) {
		t.Fatal("未修復曝光／HDR 遺失", actual)
	}
	restoredParityRecord(t, "F02", object{"exposure": 12, "hdrAmount": 45}, object{"exposure": actual["exposure"], "hdrAmount": actual["hdrAmount"]})
}

func TestSwiftParityMultiReset(t *testing.T) {
	a, path := restoredParityApp(t)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	second := filepath.Join(filepath.Dir(path), "第二張.jpg")
	if err = os.WriteFile(second, data, 0600); err != nil {
		t.Fatal(err)
	}
	fingerprint, err := storage.Fingerprint(a.ctx, second)
	if err != nil {
		t.Fatal(err)
	}
	key := storage.PhotoKey(second, fingerprint)
	recipe := a.defaults["filmPortra400"]
	fields := recipeFields(recipe)
	fields["contrast"] = float64(37)
	recipe = withFields(recipe, fields)
	if err = a.store.Save(key, storage.Document{Version: 1, Selected: recipe.Style, Recipes: map[string]contract.Recipe{recipe.Style: recipe}}); err != nil {
		t.Fatal(err)
	}
	directory, err := photos.Scan(a.ctx, filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	a.installDirectory(directory)
	a.selected, a.recipes[recipe.Style] = recipe.Style, recipe
	if err = a.refreshUI(); err != nil {
		t.Fatal(err)
	}
	if err = a.handle(object{"action": "resetAdjustments", "style": recipe.Style, "ids": []any{photos.Identity(path), photos.Identity(second)}}); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	_, secondDoc, err := a.photoDocument(a.ctx, second)
	if err != nil {
		t.Fatal(err)
	}
	if a.selected != "original" || secondDoc.Selected != "original" {
		t.Fatal("未修復只重置目前照片", a.selected, secondDoc.Selected)
	}
	restoredParityRecord(t, "F03", object{"current": "original", "second": "original"}, object{"current": a.selected, "second": secondDoc.Selected, "remainingRecipes": len(secondDoc.Recipes)})
}

func TestSwiftParityAICancelState(t *testing.T) {
	a := testApp(t)
	a.computing = true
	a.computationStep = "分析照片"
	var payload object
	a.emit = func(name string, value any) {
		if name == "handleNativeState" {
			payload = value.(object)
		}
	}
	a.sendState(true)
	if payload["isComputing"] != true || payload["canCancelComputation"] != true || payload["isCancellingComputation"] != false {
		t.Fatal("未修復取消狀態缺漏")
	}
	restoredParityRecord(t, "F04", object{"canCancelComputation": true, "isCancellingComputation": false}, object{"canCancelComputation": payload["canCancelComputation"], "isCancellingComputation": payload["isCancellingComputation"]})
	if dir := os.Getenv("PARITY_AUDIT_OUTPUT"); dir != "" {
		data, _ := json.Marshal(payload)
		if err := os.WriteFile(filepath.Join(dir, "ai-state.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSwiftParityBatchProgress(t *testing.T) {
	a := testApp(t)
	a.batch = object{"id": "稽核", "total": 3, "current": 1, "progress": float64(0), "succeeded": 0, "failed": 0}
	var payload object
	events := 0
	a.emit = func(name string, value any) {
		if name == "handleBatchExportProgress" {
			payload = value.(object)
			events++
		}
	}
	a.batchProgress(1, "第二張.jpg", "正在匯出", .5, 1, 0)
	if payload["current"] != float64(2) || payload["progress"] != .5 {
		t.Fatal("未修復批次欄位缺漏")
	}
	a.batchProgress(1, "第二張.jpg", "正在匯出", .505, 1, 0)
	a.batchProgress(0, "第一張.jpg", "過期進度", 1, 1, 0)
	if events != 1 {
		t.Fatal("批次未合併微小或過期進度", events)
	}
	restoredParityRecord(t, "F05", object{"current": 2, "progress": .5}, payload)
	if dir := os.Getenv("PARITY_AUDIT_OUTPUT"); dir != "" {
		data, _ := json.Marshal(payload)
		if err := os.WriteFile(filepath.Join(dir, "batch-state.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSwiftParitySkinWarmth(t *testing.T) {
	for _, warmth := range []float64{-35, 35} {
		a := testApp(t)
		if err := a.update(object{"key": "skinWarmth", "value": warmth}); err != nil {
			t.Fatal(err)
		}
		recipe := a.recipes[a.selected]
		job := a.job("", recipe, true)
		if !recipe.DetectSubject || !job.Recipe.DetectSubject {
			t.Fatal("未修復膚色遮罩旗標被覆寫", recipe.DetectSubject, job.Recipe.DetectSubject)
		}
		restoredParityRecord(t, "F06", object{"skinWarmth": warmth, "detectSubject": true}, object{"skinWarmth": warmth, "recipeDetectSubject": recipe.DetectSubject, "jobDetectSubject": job.Recipe.DetectSubject})
	}
}

func TestSwiftParityLensMask(t *testing.T) {
	a := testApp(t)
	a.sourceIdentity = &storage.PhotoSource{Path: "稽核.dng", Fingerprint: "稽核指紋"}
	data := make([]byte, 32)
	copy(data, "FYPMASK1")
	binary.LittleEndian.PutUint32(data[8:], 1)
	binary.LittleEndian.PutUint32(data[12:], 1)
	mask, err := a.store.ImportMask(data, a.sourceIdentity.Fingerprint, repairDigest(a.recipes[a.selected].RepairPatches))
	if err != nil {
		t.Fatal(err)
	}
	a.subjectMask = mask
	if job := a.job("", a.recipes[a.selected], true); job.SubjectMask == nil || !job.Recipe.DetectSubject {
		t.Fatal("所有人像滑桿為零時仍須沿用有效遮罩")
	}
	if err = a.setPreference("setLensCorrectionEnabled", object{"enabled": false}); err != nil {
		t.Fatal(err)
	}
	job := a.job("", a.recipes[a.selected], true)
	if a.subjectMask != nil || job.SubjectMask != nil || job.Input.LensCorrection || !job.Recipe.DetectSubject {
		t.Fatal("未修復鏡頭設定更改後仍重用遮罩")
	}
	restoredParityRecord(t, "F07", object{"lensCorrection": false, "oldMaskReused": false}, object{"lensCorrection": job.Input.LensCorrection, "oldMaskReused": job.SubjectMask != nil})
	// 模擬重開另一張以不同鏡頭設定保存的照片，仍須核對幾何條件。
	disabled := false
	mask.LensCorrection, a.subjectMask = &disabled, mask
	if job = a.job("", a.recipes[a.selected], true); job.SubjectMask == nil {
		t.Fatal("相同鏡頭設定的已保存遮罩應可重用")
	}
	a.preferences.LensCorrection = true
	if job = a.job("", a.recipes[a.selected], true); job.SubjectMask != nil || !job.Recipe.DetectSubject {
		t.Fatal("跨照片重開後沿用不同鏡頭設定的遮罩")
	}
}

func TestSwiftParityExportOverwrite(t *testing.T) {
	a, _ := restoredParityApp(t)
	target := filepath.Join(t.TempDir(), "已匯出.png")
	if err := os.WriteFile(target, []byte("原有輸出"), 0600); err != nil {
		t.Fatal(err)
	}
	var phases []string
	a.emit = func(name string, value any) {
		if name == "handleExportDevelopment" {
			phases = append(phases, value.(object)["phase"].(string))
		}
	}
	job := a.job(target, a.recipes[a.selected], false)
	if _, err := a.renderExport(a.ctx, job, false); err == nil {
		t.Fatal("未確認不得覆寫")
	}
	data, _ := os.ReadFile(target)
	if string(data) != "原有輸出" {
		t.Fatal("失敗覆寫破壞原有成品")
	}
	phases = nil
	if _, err := a.renderExport(a.ctx, job, true); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(target)
	if string(data) == "原有輸出" || len(data) == 0 {
		t.Fatal("未發布新成品")
	}
	if len(phases) < 2 || phases[0] != "begin" || phases[len(phases)-1] != "complete" {
		t.Fatal("顯影動畫未收尾", phases)
	}
}

func TestSwiftParityMCPExportSettings(t *testing.T) {
	a, _ := restoredParityApp(t)
	a.exportSettings.JPEGQuality, a.exportSettings.MaxPixel, a.exportSettings.ColorSpace = 23, 640, "displayP3"
	var output contract.ImageOutput
	backend := previewBackend{render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
		output = job.Output
		return json.RawMessage(`{}`), nil
	}}
	var err error
	a.services, err = host.New(backend)
	if err != nil {
		t.Fatal(err)
	}
	_, err = a.mcpExport(a.ctx, object{"path": filepath.Join(t.TempDir(), "稽核.jpg"), "format": "jpeg"})
	if err != nil {
		t.Fatal(err)
	}
	if output.MaxPixel != 640 || output.Quality != .23 || output.ColorSpace != "displayP3" {
		t.Fatal("未修復 MCP 忽略已保存設定", output)
	}
	restoredParityRecord(t, "F09", object{"maxPixel": 640, "quality": .23, "colorSpace": "displayP3"}, object{"maxPixel": output.MaxPixel, "quality": output.Quality, "colorSpace": output.ColorSpace})
	a.exportSettings.WebPQuality, a.exportSettings.WebPLossless = 38, true
	a.exportSettings.PNGDepth, a.exportSettings.TIFFDepth, a.exportSettings.TIFFCompression = 16, 8, 5
	for _, format := range []string{"png", "tiff", "webp"} {
		_, err = a.mcpExport(a.ctx, object{"path": filepath.Join(t.TempDir(), "稽核."+format), "format": format})
		if err != nil {
			t.Fatal(err)
		}
		depth := 8
		if format == "tiff" {
			depth = 16
		}
		if output.BitDepth != depth || output.MaxPixel != 640 || output.ColorSpace != "displayP3" || !output.WebPLossless || output.TiffCompression != 5 || format == "webp" && output.Quality != .38 {
			t.Fatal("MCP 色深契約或其他保存設定不符", format, output)
		}
	}
	_, err = a.mcpExport(a.ctx, object{"path": filepath.Join(t.TempDir(), "稽核.tiff"), "bitDepth": float64(8)})
	if err != nil || output.BitDepth != 8 {
		t.Fatal("MCP 未採用明確指定色深", output, err)
	}
}

func TestSwiftParityDuplicateSelection(t *testing.T) {
	a, source := restoredParityApp(t)
	if err := a.batchPhotos([]string{source}, "duplicate", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	entries, err := os.ReadDir(filepath.Dir(source))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || a.source == source {
		t.Fatal("未修復複製後仍停在原片", len(entries), a.source)
	}
	restoredParityRecord(t, "F10", "選取並開啟新副本", object{"current": filepath.Base(a.source), "fileCount": len(entries)})
}
