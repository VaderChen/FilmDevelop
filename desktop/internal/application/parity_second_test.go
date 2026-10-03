package application

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
	"github.com/VaderChen/FilmDevelop/internal/models"
	"github.com/VaderChen/FilmDevelop/internal/transfer"
)

func TestSwiftSecondParityPresetReselection(t *testing.T) {
	a := testApp(t)
	a.selected = "filmPortra400"
	r := a.recipes[a.selected]
	f := recipeFields(r)
	f["contrast"], f["exposure"], f["frameEnabled"], f["dateEnabled"] = float64(71), float64(23), true, true
	f["cropAspectRatio"], f["cropWidth"] = "free", float64(73)
	a.recipes[a.selected] = withFields(r, f)
	if err := a.selectStyle(a.selected); err != nil {
		t.Fatal(err)
	}
	next := recipeFields(a.recipes[a.selected])
	defaults := recipeFields(a.defaults[a.selected])
	if next["contrast"] != defaults["contrast"] || next["exposure"] != defaults["exposure"] || next["frameEnabled"] != true || next["dateEnabled"] != true || next["cropWidth"] != float64(73) {
		t.Fatal("無 AI 重選底片應恢復顯影預設、保留裝飾與照片裁切", next)
	}
	if err := a.saveFilm("重套配方", withFields(r, f), ""); err != nil {
		t.Fatal(err)
	}
	id := a.customFilms[0].ID
	if err := a.selectStyle(id); err != nil {
		t.Fatal(err)
	}
	changed := recipeFields(a.recipes[a.selected])
	changed["contrast"] = float64(12)
	a.recipes[a.selected] = withFields(r, changed)
	if err := a.selectStyle(id); err != nil {
		t.Fatal(err)
	}
	if recipeFields(a.recipes[a.selected])["contrast"] != float64(71) {
		t.Fatal("重選自訂底片未重新套用配方")
	}
}

func TestSwiftSecondParityResetHistoryAndStaleStyle(t *testing.T) {
	a, _ := restoredParityApp(t)
	a.selected = "filmPortra400"
	a.pushHistory()
	a.historyGroup = "舊手勢"
	if err := a.handle(object{"action": "resetAdjustments", "style": "original"}); err != nil {
		t.Fatal(err)
	}
	if a.selected != "filmPortra400" {
		t.Fatal("過期底片的重設操作修改目前照片")
	}
	if err := a.handle(object{"action": "resetAdjustments", "style": a.selected}); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if len(a.undo) != 0 || len(a.redo) != 0 || a.historyGroup != "" {
		t.Fatal("恢復預設仍留下復原／重做紀錄")
	}
}

func TestSwiftSecondParityRetryInvalidatesResultAndResendsImage(t *testing.T) {
	a, path := restoredParityApp(t)
	data, _ := os.ReadFile(path)
	var renders, images atomic.Int32
	backend := previewBackend{render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
		renders.Add(1)
		return json.RawMessage(`{"sourceWidth":4,"sourceHeight":3}`), os.WriteFile(job.Output.Path, data, 0600)
	}}
	a.services, _ = host.New(backend)
	a.emit = func(name string, payload any) {
		if name == "handleNativeState" {
			if value, ok := payload.(object)["outputImage"].(string); ok && value != "" {
				images.Add(1)
			}
		}
	}
	a.preview()
	a.workers.Wait()
	beforeRenders, beforeImages := renders.Load(), images.Load()
	a.preview()
	a.workers.Wait()
	if renders.Load() != beforeRenders {
		t.Fatal("一般預覽未命中快取")
	}
	a.retryPreview()
	a.workers.Wait()
	if renders.Load() <= beforeRenders || images.Load() <= beforeImages {
		t.Fatal("重試未重新渲染及重送相同影像", renders.Load(), images.Load())
	}
}

func TestSwiftSecondParityRepairCancellationAndPreparationReply(t *testing.T) {
	a := testApp(t)
	var state, preparation object
	a.emit = func(name string, payload any) {
		if name == "handleNativeState" {
			state = payload.(object)
		}
		if name == "handleRepairPreparation" {
			preparation = payload.(object)
		}
	}
	ctx, cancel := context.WithCancel(a.ctx)
	defer cancel()
	a.repairing, a.cancel = true, cancel
	if err := a.handle(object{"action": "cancelRepairBrush"}); err != nil {
		t.Fatal(err)
	}
	if ctx.Err() == nil || state["isCancellingRepair"] != true || state["repairStep"] != "正在取消修復…" {
		t.Fatal("取消修復未同步等待狀態", state)
	}
	a.repairDownloadProgress(ctx, transfer.Progress{Received: 50, Total: 100})
	if a.repairStep != "正在取消修復…" {
		t.Fatal("晚到的下載進度覆寫取消狀態")
	}
	a.repairing = false
	a.mcpMutating = true
	if err := a.handle(object{"action": "prepareRepairBrush", "photoGeneration": a.generation}); err != nil {
		t.Fatal("忙碌時應明確回覆修復準備失敗", err)
	}
	if preparation["success"] != false || preparation["photoGeneration"] != a.generation {
		t.Fatal("缺少修復準備確認", preparation)
	}
}

func TestSwiftSecondParityConfirmedFilmExport(t *testing.T) {
	path := filepath.Join(t.TempDir(), "底片.json")
	if err := writeConfirmedFile(path, []byte("第一份")); err != nil {
		t.Fatal(err)
	}
	if err := writeConfirmedFile(path, []byte("更新")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "更新" {
		t.Fatal("確認取代後未保存底片", err)
	}
	if err := writeConfirmedFile(filepath.Dir(path), []byte("不應寫入")); err == nil {
		t.Fatal("接受非一般檔案")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatal("留下暫存檔案", entries)
	}
}

func TestWindowsModelFormatsRespectNativeCapabilities(t *testing.T) {
	a := testApp(t)
	a.capabilities = object{"mlx": false}
	a.modelEntries = []models.Entry{{ID: "mlx", Format: "mlx", Ready: true, Message: "可直接使用"}, {ID: "gguf", Format: "gguf", Ready: true, Message: "可直接使用"}}
	choices := a.aiPayload()["modelChoices"].([]object)
	if choices[0]["ready"] != false || choices[0]["message"] != unsupportedMLXMessage || choices[1]["ready"] != true {
		t.Fatal("不支援 MLX 時的狀態與說明不符", choices)
	}
	if err := a.queryRepository(false, "owner/model", "mlx"); err == nil || a.modelBusy || a.repository.Loading {
		t.Fatal("不支援的平台仍開始查詢 MLX", err)
	}
	a.repository.Format = "mlx"
	a.repository.Repository = &models.Repository{ID: "owner/model"}
	if err := a.handleModels("downloadModelRepository", object{}); err == nil || a.modelBusy {
		t.Fatal("不支援的平台仍下載 MLX", err)
	}
}

func TestGGUFDownloadBecomesAvailableAfterInstall(t *testing.T) {
	a := testApp(t)
	a.capabilities = object{"mlx": false}
	a.managedModels = filepath.Join(t.TempDir(), "模型目錄")
	a.modelSettings = modelSettings{Version: 1}
	data := make([]byte, 32)
	copy(data, "GGUF")
	binary.LittleEndian.PutUint32(data[4:], 3)
	digest := sha256.Sum256(data)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); _, _ = w.Write(data) }))
	defer server.Close()
	files := []transfer.File{}
	for _, name := range []string{"vision-Q4_K_M.gguf", "mmproj-vision-F16.gguf"} {
		files = append(files, transfer.File{Path: name, URL: server.URL + "/" + name, Size: int64(len(data)), SHA256: hex.EncodeToString(digest[:])})
	}
	if err := a.installModels(a.ctx, filepath.Join(a.managedModels, "測試下載"), files); err != nil {
		t.Fatal(err)
	}
	entry, ready := a.activeModel()
	if !ready || entry.Format != "gguf" || entry.Projector == "" || requests.Load() != 2 {
		t.Fatal("下載、完整性驗證與掃描後模型未就緒", entry, requests.Load())
	}
	if a.aiPayload()["ready"] != true {
		t.Fatal("模型已就緒卻回報無法使用")
	}
}

func TestSwiftSecondParityPortraitCropTitles(t *testing.T) {
	a := testApp(t)
	for _, portrait := range []bool{true, false, true} {
		a.sourceWidth, a.sourceHeight = 4, 6
		if !portrait {
			a.sourceWidth, a.sourceHeight = 6, 4
		}
		p := object{}
		a.preferencePayload(p)
		data, _ := json.Marshal(p["cropAspectRatios"])
		var ratios []object
		_ = json.Unmarshal(data, &ratios)
		want := map[string]string{"threeTwo": "3:2", "fourThree": "4:3", "sixteenNine": "16:9"}
		if portrait {
			want = map[string]string{"threeTwo": "2:3", "fourThree": "3:4", "sixteenNine": "9:16"}
		}
		for _, r := range ratios {
			if title, ok := want[stringValue(r, "id")]; ok && r["title"] != title {
				t.Fatal("裁切比例標籤未依來源直橫式更新", r, title)
			}
		}
	}
}

func TestSwiftSecondParityExplicitLanguageReplacesMigratedPromptLanguage(t *testing.T) {
	a := testApp(t)
	a.preferences.PromptLanguage = "japanese"
	a.systemLanguage = "korean"
	for _, item := range []struct{ choice, want string }{{"en", "english"}, {"automatic", "korean"}} {
		if err := a.setPreference("setLanguage", object{"preference": item.choice}); err != nil {
			t.Fatal(err)
		}
		if a.effectivePromptLanguage() != item.want {
			t.Fatal("介面切換語言後仍用舊提示詞語言", a.effectivePromptLanguage())
		}
		if err := a.loadPreferences(); err != nil {
			t.Fatal(err)
		}
		if a.effectivePromptLanguage() != item.want {
			t.Fatal("語言偏好未保存")
		}
	}
}

func TestSwiftSecondParityFreshPNGDepth(t *testing.T) {
	a := testApp(t)
	if a.exportSettings.PNGDepth != 8 {
		t.Fatal("首次安裝 PNG 預設應為 8 位元", a.exportSettings.PNGDepth)
	}
	a.exportSettings.PNGDepth = 16
	if err := a.savePreferences(); err != nil {
		t.Fatal(err)
	}
	if err := a.loadPreferences(); err != nil {
		t.Fatal(err)
	}
	if a.exportSettings.PNGDepth != 16 {
		t.Fatal("明確設定的 16 位元不應被重設")
	}
}

func TestSwiftSecondParityDeletedFilmDoesNotReturnFromHistoryOrPhoto(t *testing.T) {
	a, path := restoredParityApp(t)
	if err := a.saveFilm("將刪除的底片", a.recipes[a.selected], ""); err != nil {
		t.Fatal(err)
	}
	id := a.customFilms[0].ID
	if err := a.selectStyle(id); err != nil {
		t.Fatal(err)
	}
	stale := a.snapshot()
	a.undo = append(a.undo, stale)
	a.redo = append(a.redo, stale)
	if err := a.persist(); err != nil {
		t.Fatal(err)
	}
	if err := a.handleLibrary("deleteCustomFilm", object{"id": id}); err != nil {
		t.Fatal(err)
	}
	if err := a.resolveDialog(object{"id": a.dialog.ID, "value": "delete"}); err != nil {
		t.Fatal(err)
	}
	for _, list := range [][]editSnapshot{a.undo, a.redo} {
		for _, s := range list {
			if s.CustomID == id || s.CustomBase != nil {
				t.Fatal("歷史仍引用已刪除的底片")
			}
		}
	}
	if err := a.restore(stale); err != nil {
		t.Fatal(err)
	}
	if a.selectedCustom != "" || !reflect.DeepEqual(a.recipes, stale.Recipes) {
		t.Fatal("還原失效身分時應僅解除名稱，保留配方")
	}
	a.selectedCustom = id
	a.customBase = stale.CustomBase
	if err := a.persist(); err != nil {
		t.Fatal(err)
	}
	if err := a.OpenImage(path); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.selectedCustom != "" || a.customBase != nil {
		t.Fatal("照片重開恢復了已刪除底片")
	}
}

func TestSwiftSecondParitySaveAndDuplicateFilmSelection(t *testing.T) {
	a, _ := restoredParityApp(t)
	if err := a.handleLibrary("saveCustomFilm", object{}); err != nil {
		t.Fatal(err)
	}
	if err := a.resolveDialog(object{"id": a.dialog.ID, "value": "新底片"}); err != nil {
		t.Fatal(err)
	}
	id := a.customFilms[0].ID
	if a.selectedCustom != id || a.customBase == nil || len(a.undo) == 0 {
		t.Fatal("儲存後未選取底片或記錄身分變更")
	}
	if err := a.handleLibrary("showCustomFilmMenu", object{"id": id}); err != nil {
		t.Fatal(err)
	}
	if err := a.resolveDialog(object{"id": a.dialog.ID, "value": "duplicate"}); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.dialog != nil || len(a.customFilms) != 2 || a.selectedCustom == id || a.customFilms[1].Name != "新底片 副本" {
		t.Fatal("拷貝副本應直接建立並套用", a.customFilms)
	}
}

func TestSwiftSecondParityRAWFailureRestoresConfiguration(t *testing.T) {
	a, path := restoredParityApp(t)
	a.capabilities = object{"rawDecoders": []any{"system", "software"}}
	a.rawDecoder = "system"
	a.renderInfo = object{"rawDecoder": "system"}
	a.sourcePreview = "原始照片"
	a.outputPreview = "目前照片"
	data, _ := os.ReadFile(path)
	a.services, _ = host.New(previewBackend{render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
		if job.Input.RawDecoder == "software" {
			return nil, errors.New("模擬 RAW 解析失敗")
		}
		return json.RawMessage(`{"sourceWidth":4,"sourceHeight":3,"rawDecoder":"system"}`), os.WriteFile(job.Output.Path, data, 0600)
	}})
	if err := a.setRAWDecoderBackend("software"); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.rawDecoder != "system" || a.sourcePreview != "原始照片" {
		t.Fatal("RAW 切換失敗未恢復原本解析設定與照片", a.rawDecoder, a.sourcePreview)
	}
	if err := a.loadPreferences(); err != nil {
		t.Fatal(err)
	}
	if a.rawDecoder != "system" {
		t.Fatal("失敗的 RAW 設定不應持久化")
	}
}
