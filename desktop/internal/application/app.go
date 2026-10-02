// Package application 是 Go 宿主的應用層，不執行影像像素計算。
package application

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/VaderChen/FilmDevelop/internal/host"
	"github.com/VaderChen/FilmDevelop/internal/mcp"
	"github.com/VaderChen/FilmDevelop/internal/models"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	"github.com/VaderChen/FilmDevelop/internal/transfer"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type object = map[string]any
type App struct {
	pendingNativeFile, nativeFileID                       string
	uiReady                                               bool
	manual                                                storage.ManualAdjustments
	closing, allowClose                                   bool
	checkingUpdate, updating                              bool
	updateState                                           updateState
	mcpServer                                             *mcp.Server
	mcpMessage, mcpFlushID, lastMessage, lastExportedPath string
	mcpMutating                                           bool
	mcpFlush                                              chan struct{}
	previewError                                          error
	repairing                                             bool
	repairStep                                            string
	repairProgress                                        object
	legacySettings                                        object
	migrationIssues                                       []migrationIssue
	migrationMu                                           sync.Mutex
	decorations                                           map[string]object
	subjectMask                                           *storage.SubjectMask
	sourceIdentity                                        *storage.PhotoSource
	legacyPhotoDirectory                                  string
	computing                                             bool
	computationStep                                       string
	modelSettings                                         modelSettings
	modelEntries                                          []models.Entry
	managedModels, modelMessage, modelOperation           string
	modelBusy                                             bool
	modelCancel                                           context.CancelFunc
	modelProgress                                         transfer.Progress
	repository                                            repositoryState
	repositoryCancel                                      context.CancelFunc

	emit              func(string, any)
	cropPreview       string
	skipSubject       bool
	interaction       string
	previewTimer      *time.Timer
	adjustmentPreview adjustmentPreviewState
	editVersion       uint64

	organization organization
	recent       []string
	copiedRecipe *storage.Document
	batch        object

	preferences              Preferences
	systemLanguage           string
	capabilities, renderInfo object
	hoverCancel              context.CancelFunc
	hoverID                  string
	selectedCustom           string
	customBase               *contract.Recipe
	customFilms              []CustomFilm
	prompts                  map[string]map[string]string
	dialog                   *pendingDialog

	mu                           sync.Mutex
	preferencesMu                sync.Mutex
	stateMu                      sync.Mutex
	sentPreviewImages            map[string]string
	previewResults               previewResultCache
	openMu                       sync.Mutex
	workers                      sync.WaitGroup
	ctx                          context.Context
	stop                         context.CancelFunc
	ready                        chan struct{}
	initError                    error
	services                     *host.Service
	store                        *storage.Store
	imageKey                     string
	commands                     chan object
	catalog                      object
	recipes                      map[string]contract.Recipe
	defaults                     map[string]contract.Recipe
	ui                           map[string]object
	defaultUI                    map[string]object
	selected, source, generation string
	sourcePreview, outputPreview string
	loadingPreview               string
	previewPhase                 string
	computeSwitchRequestID       string
	computeSwitchPreparing       bool
	computeSwitchRevision        uint64
	revision                     uint64
	cancel                       context.CancelFunc
	rendering, saving            bool
	undo, redo                   []editSnapshot
	sourceWidth, sourceHeight    int
	historyGroup                 string
	exportSettings               ExportSettings
	computeBackend, rawDecoder   string
	directory                    photos.Directory
	directoryRevision            uint64
	directoryScanning            bool
	directoryMessage             string
	thumbnailServices            *host.Service
	thumbnailCache               photos.Cache
	thumbnailGate                chan struct{}
	thumbnailWork                map[string]*thumbnailWork
	thumbnails                   map[string]string
	thumbnailFailed              map[string]bool
	directoryPicker              func(context.Context, wruntime.OpenDialogOptions) (string, error)
}

func New(binary string) (*App, error) {
	services, err := host.New(engine.New(binary))
	if err != nil {
		return nil, err
	}
	app := &App{services: services, commands: make(chan object, 128), ready: make(chan struct{}),
		recipes: make(map[string]contract.Recipe), defaults: make(map[string]contract.Recipe), catalog: object{"styles": []any{}},
		ui: make(map[string]object), defaultUI: make(map[string]object), selected: "original", generation: identifier(),
		exportSettings: defaultExportSettings(), computeBackend: "system", rawDecoder: "system"}
	app.store, err = storage.New()
	if err != nil {
		return nil, err
	}
	if os.Getenv("FILMDEVELOP_DATA_DIR") == "" {
		root, e := os.UserConfigDir()
		if e != nil {
			return nil, e
		}
		app.legacyPhotoDirectory = filepath.Join(root, "PhotoStyleApp", "PhotoEdits")
	}
	app.thumbnailServices, err = host.New(engine.New(binary))
	if err != nil {
		return nil, err
	}
	dataDirectory, err := storage.DataDirectory()
	if err != nil {
		return nil, err
	}
	app.thumbnailCache = photos.Cache{Directory: filepath.Join(dataDirectory, "thumbnails")}
	app.thumbnailGate = make(chan struct{}, 2)
	app.thumbnailWork = make(map[string]*thumbnailWork)
	app.thumbnails = make(map[string]string)
	app.thumbnailFailed = make(map[string]bool)
	app.directoryMessage = "請選取照片目錄，以瀏覽下方的照片列表。"
	app.directoryPicker = wruntime.OpenDirectoryDialog
	_, _ = app.store.LoadState("migration-issues.json", &app.migrationIssues)
	if err = app.loadPreferences(); err != nil {
		app.recoverState("preferences.json", err)
		if err = app.loadPreferences(); err != nil {
			return nil, err
		}
	}
	return app, err
}

func identifier() string { var b [16]byte; _, _ = rand.Read(b[:]); return hex.EncodeToString(b[:]) }
func clone[T any](v T) T {
	data, _ := json.Marshal(v)
	var out T
	_ = json.Unmarshal(data, &out)
	return out
}

func (a *App) Startup(ctx context.Context) {
	ctx, a.stop = context.WithCancel(ctx)
	a.ctx = ctx
	wruntime.EventsOn(ctx, "filmdevelop:command", func(args ...interface{}) {
		if len(args) == 1 {
			if message, ok := args[0].(map[string]interface{}); ok {
				select {
				case a.commands <- message:
				case <-ctx.Done():
				}
			}
		}
	})
	wruntime.EventsOn(ctx, "filmdevelop:ordered-command", func(args ...interface{}) {
		if len(args) != 1 {
			return
		}
		envelope, ok := args[0].(map[string]interface{})
		if !ok {
			return
		}
		message, ok := envelope["payload"].(map[string]interface{})
		if !ok {
			return
		}
		select {
		case a.commands <- message:
			wruntime.EventsEmit(ctx, "filmdevelop:command-accepted", envelope["id"])
		case <-ctx.Done():
		}
	})
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		var nativeError error
		err := a.loadCatalog()
		if err == nil {
			if e := a.loadUserLibrary(); e != nil {
				a.migrationProblem("底片庫", e, "")
			}
			a.loadOrganizationSafely()
			nativeError = a.loadCapabilities()
			if e := a.migrateLegacySettings(); e != nil {
				a.migrationProblem("舊版設定", e, "")
			}
			if e := a.archiveLegacyPhotos(); e != nil {
				a.migrationProblem("舊照片資產", e, "")
			}
			if e := a.loadDecorations(); e != nil {
				a.recoverState("decorations.json", e)
			}
			if nativeError == nil {
				if e := a.reconcileAcceleration(); e != nil {
					a.migrationProblem("加速設定", e, "")
				}
			}
			if e := a.loadModels(); e != nil {
				a.recoverState("models.json", e)
				if e = a.loadModels(); e != nil {
					a.migrationProblem("模型設定", e, "")
				}
			}
			if e := a.loadUpdates(); e != nil {
				a.migrationProblem("更新設定", e, "")
			}
		}
		a.mu.Lock()
		a.initError = err
		a.mu.Unlock()
		if err != nil {
			a.toast(err)
		} else if nativeError != nil {
			a.toast(fmt.Errorf("影像引擎無法啟動；共用設定與資料管理仍可使用：%w", nativeError))
		}
		if err == nil && a.preferences.MCPEnabled {
			if e := a.startMCP(); e != nil {
				a.toast(e)
			}
		}
		close(a.ready)
		a.state()
		if err == nil {
			a.startUpdateCheck()
		}
		if err == nil {
			if err := a.restoreBrowser(); err != nil {
				a.toast(err)
			}
		}
		for {
			select {
			case message := <-a.commands:
				if err := a.handle(message); err != nil {
					a.toast(err)
					a.state()
				} else if action, _ := message["action"].(string); action == "setStyle" || (action == "updateAdjustment" && stringValue(message, "interactionID") == "") || action == "undoEdit" || action == "redoEdit" || action == "resetAdjustments" || action == "saveImage" {
					if err := a.persist(); err != nil {
						a.toast(err)
					}
					if action != "saveImage" && action != "setStyle" {
						if err := a.rememberDecorations(); err != nil {
							a.toast(err)
						}
					}
				}
			case <-ctx.Done():
				return
			}
		}
	}()
}

// 平台引擎不可用時保留 Go 共用功能，讓缺少硬體模組不阻斷整個 UI。
func (a *App) loadCapabilities() error {
	a.capabilities = object{"available": false, "mlx": false, "computeBackends": []any{}, "rawDecoders": []any{}}
	data, err := a.services.Native(a.ctx, "capabilities", object{}, nil)
	if err != nil {
		return err
	}
	var capabilities object
	if err = json.Unmarshal(data, &capabilities); err != nil {
		return err
	}
	if _, ok := capabilities["computeBackends"].([]any); !ok {
		return errors.New("影像引擎能力資料不完整")
	}
	if _, ok := capabilities["rawDecoders"].([]any); !ok {
		return errors.New("影像引擎解析能力資料不完整")
	}
	capabilities["available"] = true
	a.capabilities = capabilities
	return nil
}

func (a *App) loadCatalog() error {
	result, err := a.services.Catalog()
	if err != nil {
		return err
	}
	var catalog object
	if err := json.Unmarshal(result, &catalog); err != nil {
		return err
	}
	entries, ok := catalog["styles"].([]any)
	if !ok || len(entries) == 0 {
		return errors.New("共用底片目錄不完整")
	}
	recipes := make(map[string]contract.Recipe)
	ui := make(map[string]object)
	for _, entry := range entries {
		style, ok := entry.(object)
		id, validID := style["id"].(string)
		projection, validUI := style["uiAdjustment"].(object)
		adjustment, validAdjustment := style["adjustment"].(object)
		if !ok || !validID || id == "" || !validUI || !validAdjustment {
			return errors.New("共用底片目錄格式錯誤")
		}
		if _, exists := recipes[id]; exists {
			return errors.New("底片識別重複")
		}
		raw, err := json.Marshal(adjustment)
		if err != nil {
			return err
		}
		recipes[id] = contract.Recipe{Version: 1, Style: id, Adjustment: raw, RepairPatches: json.RawMessage(`[]`)}
		ui[id] = projection
		delete(style, "adjustment")
		delete(style, "uiAdjustment")
	}
	if _, ok := recipes["original"]; !ok {
		return errors.New("共用目錄缺少原片配方")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.catalog = catalog
	a.recipes = recipes
	a.defaults = clone(recipes)
	a.ui = ui
	a.defaultUI = clone(ui)
	return nil
}

func (a *App) Shutdown(context.Context) {
	if a.stop != nil {
		a.stop()
	}
	a.mu.Lock()
	if a.cancel != nil {
		a.cancel()
	}
	if a.previewTimer != nil {
		a.previewTimer.Stop()
	}
	server := a.mcpServer
	a.mcpServer = nil
	a.mu.Unlock()
	if server != nil {
		server.Close()
	}
	// 原生程序退出與暫存清理完成後，宿主才結束。
	a.workers.Wait()
	_ = a.services.Close()
	_ = a.thumbnailServices.Close()
}

// 先提交前端尚未送出的滑桿／裁切，再由正常結束流程取消並排空原生工作。
func (a *App) BeforeClose(context.Context) bool {
	a.mu.Lock()
	allowed, requested := a.allowClose, a.closing
	if !allowed {
		a.closing = true
	}
	a.mu.Unlock()
	if !allowed && !requested {
		a.reply("handleHostClose", object{})
	}
	return !allowed
}
func (a *App) toast(err error) {
	a.mu.Lock()
	a.lastMessage = err.Error()
	a.mu.Unlock()
	a.reply("handleNativeToast", object{"message": err.Error()})
}
func (a *App) state() {
	a.sendState(false)
}

func (a *App) sendState(full bool) {
	// 序列發布影像差量，避免不同工作回覆交錯而遺失需顯示的影像。
	a.stateMu.Lock()
	defer a.stateMu.Unlock()
	a.mu.Lock()
	sourceName := ""
	if a.source != "" {
		sourceName = filepath.Base(a.logicalSourcePath())
	}
	previewPhase := ""
	previewBusy := a.previewBusy()
	if previewBusy {
		previewPhase = a.previewPhase
		if previewPhase == "" {
			previewPhase = "render"
		}
	}
	payload := object{
		"appVersion":    BuildVersion(),
		"selectedStyle": a.selected, "selectedCustomFilmID": a.selectedCustom, "styles": a.stylePayloads(), "adjustments": a.ui,
		"exportSettings": a.exportSettings, "computeBackend": a.computeBackend, "rawDecoderBackend": a.rawDecoder,
		"adjustmentDefaults": a.currentDefaults(), "sourceFileName": sourceName,
		"photoDirectory": a.directoryPayload(),
		"hasImage":       a.source != "", "photoGeneration": a.generation, "previewRevision": a.revision,
		"sourceImage": a.sourcePreview, "cropSourceImage": a.cropPreview, "repairSourceImage": a.cropPreview, "outputImage": a.outputPreview,
		"loadingPreviewImage":           a.loadingPreview,
		"previewPhase":                  previewPhase,
		"isSwitchingComputeBackend":     a.switchingComputeBackend(),
		"computeBackendSwitchRequestID": a.computeSwitchRequestID,
		"sourceImageSize":               object{"width": a.renderInfo["cropWidth"], "height": a.renderInfo["cropHeight"]},
		"cropSourceImageSize":           object{"width": a.sourceWidth, "height": a.sourceHeight},
		"canSave":                       a.outputPreview != "" && !previewBusy && !a.saving,
		"isMCPMutating":                 a.mcpMutating || a.updating,
		"isComputing":                   a.computing, "computationStep": a.computationStep,
		"isRenderingPreview": previewBusy, "isSavingImage": a.saving, "batchExport": a.batch,
		"canUndo": len(a.undo) > 0, "canRedo": len(a.redo) > 0,
		"frameStyles": a.catalog["frameStyles"], "dateStyles": a.catalog["dateStyles"],
		"filmIlluminants": a.catalog["filmIlluminants"], "printRecipes": a.catalog["printRecipes"],
		"isRepairingImage": a.repairing, "repairStep": a.repairStep, "repairModelProgress": a.repairProgress, "repairRevision": a.repairRevision(),
		"mcp": a.mcpPayload(),
		// 一般預覽的遮罩運算透過 previewPhase 在照片下方回報，不鎖住 UI。
		"subjectMask": object{"available": a.capabilities["available"] == true, "detecting": false},
		"ai":          a.aiPayload(),
	}
	a.preferencePayload(payload)
	if a.sentPreviewImages == nil {
		a.sentPreviewImages = make(map[string]string)
	}
	for _, key := range []string{"sourceImage", "cropSourceImage", "repairSourceImage", "outputImage", "loadingPreviewImage"} {
		value := payload[key].(string)
		previous, sent := a.sentPreviewImages[key]
		if !full && sent && value == previous {
			delete(payload, key)
		}
		a.sentPreviewImages[key] = value
	}
	payload = clone(payload)
	a.mu.Unlock()
	a.reply("handleNativeState", payload)
	a.requestNativeFile()
}

func (a *App) handle(message object) error {
	action, _ := message["action"].(string)
	if action == "syncUIPreferences" {
		return a.syncUIPreferences(message)
	}
	if action == "continueAdjustmentPreview" {
		a.continueAdjustment(message)
		return nil
	}
	if action == "setComputeBackend" {
		// 成功、無變更與驗證失敗皆確認同一筆要求，前端才能結束即時等待狀態。
		defer func() {
			a.mu.Lock()
			a.computeSwitchRequestID = stringValue(message, "requestID")
			a.mu.Unlock()
			a.state()
		}()
	}
	if action == "confirmClose" {
		if changes, ok := message["adjustments"]; ok {
			if err := a.update(object{"adjustments": changes, "photoGeneration": message["photoGeneration"]}); err != nil {
				a.mu.Lock()
				a.closing = false
				a.mu.Unlock()
				return err
			}
		}
		if err := a.persist(); err != nil {
			a.mu.Lock()
			a.closing = false
			a.mu.Unlock()
			return err
		}
		a.mu.Lock()
		a.allowClose = true
		a.mu.Unlock()
		wruntime.Quit(a.ctx)
		return nil
	}
	if action == "mcpRequest" {
		a.beginMCP(message["request"].(*mcpRequest))
		return nil
	}
	if action == "mcpUIReady" {
		a.mu.Lock()
		if message["id"] == a.mcpFlushID && a.mcpFlush != nil {
			close(a.mcpFlush)
			a.mcpFlush = nil
		}
		a.mu.Unlock()
		return nil
	}
	if action == "cancelFilmHover" {
		a.cancelHover(stringValue(message, "requestID"))
		return nil
	}
	if action == "previewFilmHover" {
		return a.filmHover(message)
	}
	a.mu.Lock()
	saving := a.saving || a.computing || a.repairing || a.mcpMutating || a.updating || a.switchingComputeBackend()
	initError := a.initError
	a.mu.Unlock()
	if initError != nil && action != "setLanguage" {
		return fmt.Errorf("宿主資料尚未就緒：%w", initError)
	}
	if saving && action != "resolveDialog" && action != "getState" && action != "requestNativeFile" && action != "cancelComputation" && action != "cancelRepairBrush" && action != "endAdjustmentPreview" && action != "requestPhotoThumbnails" {
		return errors.New("請等待目前處理完成")
	}
	// 切換照片、目錄或底片前，先提交前端尚未送出的調整。
	if commitActions[action] {
		if changes, ok := message["adjustments"]; ok {
			if err := a.update(object{"adjustments": changes, "photoGeneration": message["photoGeneration"]}); err != nil {
				return err
			}
			if err := a.persist(); err != nil {
				return err
			}
		}
	}
	switch action {
	case "showMigrationReport":
		return a.showDialog("資料移轉紀錄", a.migrationSummary(), "", []dialogChoice{{ID: "close", Label: "關閉"}}, func(string) error { return nil })
	case "exportLibraryArchive":
		return a.exportLibraryArchive()
	case "importLibraryArchive":
		return a.importLibraryArchive()
	case "getState":
		a.mu.Lock()
		a.uiReady = true
		a.mu.Unlock()
		a.sendState(true)
		a.requestNativeFile()
		return nil
	case "requestNativeFile":
		a.requestNativeFile()
		return nil
	case "openNativeFile":
		a.mu.Lock()
		if stringValue(message, "id") != a.nativeFileID || a.pendingNativeFile == "" {
			a.mu.Unlock()
			return errors.New("原生開檔要求已失效")
		}
		path := a.pendingNativeFile
		a.pendingNativeFile, a.nativeFileID = "", ""
		a.mu.Unlock()
		return a.OpenImage(path)
	case "browseFiles":
		path, err := wruntime.OpenFileDialog(a.ctx, wruntime.OpenDialogOptions{Title: "選取照片", Filters: []wruntime.FileFilter{{DisplayName: "影像", Pattern: "*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.webp;*.heic;*.dng;*.nef;*.cr2;*.cr3;*.arw;*.raf"}}})
		if err != nil || path == "" {
			return err
		}
		return a.OpenImage(path)
	case "browsePhotoDirectory":
		a.mu.Lock()
		current := a.directory.Path
		a.mu.Unlock()
		path, err := a.directoryPicker(a.ctx, wruntime.OpenDialogOptions{Title: "選取照片目錄", DefaultDirectory: current})
		if err != nil || path == "" {
			return err
		}
		return a.OpenDirectory(path)
	case "selectDirectoryPhoto":
		id, _ := message["id"].(string)
		a.mu.Lock()
		entry, ok := a.directory.ByID[id]
		same := entry.Path == a.source
		a.mu.Unlock()
		if !ok {
			return errors.New("照片已不在目前目錄中")
		}
		if same {
			return nil
		}
		return a.OpenImage(entry.Path)
	case "requestPhotoThumbnails":
		var ids []string
		data, err := json.Marshal(message["ids"])
		if err != nil {
			return err
		}
		if err = json.Unmarshal(data, &ids); err != nil {
			return errors.New("縮圖清單格式不符")
		}
		return a.requestThumbnails(ids)
	case "setStyle":
		id, _ := message["style"].(string)
		if id == "" {
			id, _ = message["id"].(string)
		}
		if err := a.selectStyle(id); err != nil {
			return err
		}
		a.preview()
		return nil
	case "beginAdjustmentPreview":
		a.beginAdjustment(message)
		return nil
	case "endAdjustmentPreview":
		return a.endAdjustment(message)
	case "updateAdjustment":
		if err := a.update(message); err != nil {
			return err
		}
		if stringValue(message, "interactionID") == "" {
			a.preview()
		} else {
			a.startPreviewMode(false, true, 0)
		}
		return nil
	case "undoEdit", "redoEdit":
		a.mu.Lock()
		from, to := &a.undo, &a.redo
		if action == "redoEdit" {
			from, to = &a.redo, &a.undo
		}
		if len(*from) > 0 {
			*to = append(*to, a.snapshot())
			recipe := (*from)[len(*from)-1]
			*from = (*from)[:len(*from)-1]
			if err := a.restore(recipe); err != nil {
				a.mu.Unlock()
				return err
			}
		}
		a.mu.Unlock()
		a.preview()
		return nil
	case "resetAdjustments":
		a.mu.Lock()
		a.pushHistory()
		a.manual = storage.ManualAdjustments{PrintControls: []string{}, HasCompleteHistory: true}
		a.recipes = clone(a.defaults)
		a.selected = "original"
		a.selectedCustom = ""
		a.customBase = nil
		err := a.refreshUI()
		a.mu.Unlock()
		if err != nil {
			return err
		}
		a.preview()
		return nil
	case "saveImage":
		if changes, ok := message["adjustments"]; ok {
			if err := a.update(object{"adjustments": changes}); err != nil {
				return err
			}
		}
		return a.export()
	case "setExportSettings":
		a.mu.Lock()
		key, _ := message["key"].(string)
		err := a.exportSettings.update(key, message["value"])
		a.mu.Unlock()
		if err != nil {
			return err
		}
		if err = a.savePreferences(); err != nil {
			return err
		}
		a.state()
		return nil
	case "setComputeBackend":
		return a.setComputeBackend(stringValue(message, "backend"))
	case "setRAWDecoderBackend":
		return a.setRAWDecoderBackend(stringValue(message, "backend"))
	case "prepareRepairBrush", "applyRepairBrush", "cancelRepairBrush":
		return a.repairBrush(action, message)
	case "checkAppUpdate":
		return a.checkUpdate(message["automatic"] != true)
	case "acknowledgeUpdateNotice":
		return a.acknowledgeUpdate(message)
	case "setMCPEnabled":
		return a.setMCP(message)
	case "copyMCPConfiguration":
		return a.copyMCPConfiguration()
	case "applyStyle":
		return a.applyAI()
	case "cancelComputation":
		a.mu.Lock()
		if a.cancel != nil {
			a.cancel()
		}
		a.mu.Unlock()
		return nil
	case "cancelSubjectMaskDetection":
		a.mu.Lock()
		a.skipSubject = true
		if a.cancel != nil {
			a.cancel()
		}
		a.mu.Unlock()
		a.preview()
		return nil
	case "retryPreview":
		a.preview()
		return nil
	case "setLanguage", "setShowAllFilms", "setExposureExpansionEnabled", "setModernFilmExposureEnabled", "setHighlightProtectionEnabled", "setLensCorrectionEnabled", "setHDRFeatureEnabled", "setOriginalResolutionEditing":
		return a.setPreference(action, message)
	case "chooseExportDirectory":
		return a.chooseExportDirectory()
	case "sampleWhiteBalance":
		return a.sampleWhiteBalance(message)
	case "importColorCalibration", "clearColorCalibration":
		if err := a.colorCalibration(action == "clearColorCalibration"); err != nil {
			return err
		}
		if err := a.persist(); err != nil {
			return err
		}
		a.preview()
		return nil
	case "saveCustomFilm", "importCustomFilm", "exportCustomFilm", "deleteCustomFilm", "showCustomFilmMenu", "updateStylePrompt", "resetStylePrompt":
		return a.handleLibrary(action, message)
	case "showPreviewMenu":
		return a.previewMenu(message)
	case "showRecentPhotoDirectories":
		return a.recentDirectories(message)
	case "openCustomModel", "openModelDirectory", "selectModel", "cancelModelDirectoryScan", "searchModelRepositories", "inspectModelRepository", "cancelModelRepositoryQuery", "downloadModelRepository", "downloadPreset", "deletePreset", "cancelImport", "cancelDownload", "setActiveModel":
		return a.handleModels(action, message)
	case "resolveDialog":
		return a.resolveDialog(message)
	default:
		return fmt.Errorf("無法辨識介面操作：%s", action)
	}
}

// 呼叫方持有 openMu，避免同時開檔時舊照片覆蓋較新的選取。
func (a *App) openImage(path string) error {
	select {
	case <-a.ready:
	case <-a.ctx.Done():
		return a.ctx.Err()
	}
	a.mu.Lock()
	initError := a.initError
	a.mu.Unlock()
	if initError != nil {
		return initError
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("請選擇一般影像檔案")
	}
	key, saved, err := a.photoDocument(a.ctx, path)
	if err != nil {
		return err
	}
	// 兩個平台由同一個 Go 遷移器讀取已存配方，再交給各自的硬體引擎。
	if saved != nil {
		for id, recipe := range saved.Recipes {
			if id != recipe.Style {
				return errors.New("調整紀錄的底片識別不符")
			}
			result, err := a.services.NormalizeRecipe(recipe)
			if err != nil {
				return err
			}
			saved.Recipes[id] = result
		}
	}
	a.mu.Lock()
	if a.saving {
		a.mu.Unlock()
		return errors.New("請等待匯出完成")
	}
	a.source = path
	a.imageKey = key
	a.generation = identifier()
	a.sourcePreview = ""
	a.cropPreview = ""
	a.skipSubject = false
	a.interaction = ""
	a.outputPreview = ""
	a.loadingPreview = a.thumbnails[photos.Identity(path)]
	a.undo = nil
	a.redo = nil
	a.historyGroup = ""
	a.recipes = clone(a.defaults)
	if saved.Fresh {
		a.recipes = a.newPhotoRecipes()
	}
	a.subjectMask = nil
	a.sourceIdentity = clone(saved.Source)
	a.selected = "original"
	a.manual = storage.ManualAdjustments{PrintControls: []string{}, HasCompleteHistory: true}
	a.selectedCustom = ""
	a.customBase = nil
	if saved != nil {
		a.subjectMask = clone(saved.SubjectMask)
		if saved.Manual != nil {
			a.manual = clone(*saved.Manual)
		} else {
			a.manual.HasCompleteHistory = false
		}
		a.selectedCustom = saved.CustomID
		a.customBase = clone(saved.CustomBase)
		for id, recipe := range saved.Recipes {
			a.recipes[id] = recipe
		}
		if _, ok := a.recipes[saved.Selected]; ok {
			a.selected = saved.Selected
		}
	}
	if err := a.refreshUI(); err != nil {
		a.mu.Unlock()
		return err
	}
	a.mu.Unlock()
	// 先保存已還原的配方及標記，避免只修正畫面、下次開圖又讀到空白紀錄。
	if err := a.persist(); err != nil {
		return err
	}
	a.preview()
	return nil
}

func (a *App) persist() error {
	a.mu.Lock()
	key := a.imageKey
	document := storage.Document{Source: clone(a.sourceIdentity), SubjectMask: clone(a.subjectMask), Version: 1, CustomID: a.selectedCustom, CustomBase: clone(a.customBase), Selected: a.selected, Recipes: make(map[string]contract.Recipe)}
	manual := clone(a.manual)
	document.Manual = &manual
	for id, recipe := range a.recipes {
		current, _ := json.Marshal(recipe)
		baseline, _ := json.Marshal(a.defaults[id])
		if string(current) != string(baseline) {
			document.Recipes[id] = clone(recipe)
		}
	}
	a.mu.Unlock()
	if key == "" {
		return nil
	}
	if err := a.store.Save(key, document); err != nil {
		return err
	}
	return a.markEdited()
}

func (a *App) update(message object) error {
	a.mu.Lock()
	if generation, ok := message["photoGeneration"].(string); ok && generation != a.generation {
		a.mu.Unlock()
		return errors.New("照片已切換，舊調整已取消")
	}
	if a.saving {
		a.mu.Unlock()
		return errors.New("請等待匯出完成")
	}
	changes := []any{message}
	if values, ok := message["adjustments"].([]any); ok {
		changes = values
	}
	if values, ok := message["adjustments"].([]object); ok {
		changes = make([]any, len(values))
		for i, value := range values {
			changes[i] = value
		}
	}
	if len(changes) == 0 {
		a.mu.Unlock()
		return nil
	}
	for _, raw := range changes {
		if change, ok := raw.(object); ok {
			if style, ok := change["style"].(string); ok && style != "" && style != a.selected {
				a.mu.Unlock()
				return errors.New("底片已切換，舊調整已取消")
			}
		}
	}
	recipe := clone(a.recipes[a.selected])
	generation, selected := a.generation, a.selected
	group, _ := message["interactionID"].(string)
	if group != "" && group != a.interaction {
		a.mu.Unlock()
		return errors.New("拖曳工作已失效")
	}
	a.mu.Unlock()
	rawChanges, err := json.Marshal(changes)
	if err != nil {
		return err
	}
	updated, err := a.services.EditRecipe(contract.EditorRequest{Recipe: recipe, Changes: rawChanges})
	if err != nil {
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if generation != a.generation || selected != a.selected {
		return errors.New("照片已切換，舊調整已取消")
	}
	manual := clone(a.manual)
	for _, raw := range changes {
		if change, ok := raw.(object); ok {
			key, _ := change["key"].(string)
			switch key {
			case "printExposure", "printExposureHighlights", "printExposureMidtones", "printExposureShadows", "printContrast":
				if !contains(manual.PrintControls, key) {
					manual.PrintControls = append(manual.PrintControls, key)
				}
			}
		}
	}
	if reflect.DeepEqual(recipe, updated) && reflect.DeepEqual(a.manual, manual) {
		return nil
	}
	if group != "" && group != a.interaction {
		return errors.New("拖曳工作已失效")
	}
	projection, err := a.services.ProjectRecipes(map[string]contract.Recipe{a.selected: updated})
	if err != nil {
		return err
	}
	if group == "" || group != a.historyGroup {
		a.pushHistory()
	}
	a.historyGroup = group
	a.manual = manual
	if len(a.undo) > 100 {
		a.undo = a.undo[len(a.undo)-100:]
	}
	a.redo = nil
	if group == "" {
		a.invalidatePreview()
	}
	a.recipes[a.selected] = updated
	a.ui[a.selected] = projection[a.selected]
	a.editVersion++
	return nil
}

// 呼叫方持有 mu；兩平台共用 Go 的 Web 投影，毋須啟動原生程序。
func (a *App) refreshUI() error {
	a.invalidatePreview()
	result, err := a.services.ProjectRecipes(a.recipes)
	if err != nil {
		return err
	}
	a.ui = result
	return nil
}

func (a *App) job(path string, recipe contract.Recipe, preview bool) contract.RenderJob {
	fields := recipeFields(recipe)
	recipe.DetectSubject = false
	for _, key := range []string{"backgroundBlur", "skinWhitening", "skinSmoothing"} {
		v, _ := fields[key].(float64)
		if v > 0 {
			recipe.DetectSubject = !a.skipSubject
		}
	}

	job := contract.RenderJob{Input: contract.ImageInput{Path: a.source, RawDecoder: a.rawDecoder, LensCorrection: a.preferences.LensCorrection},
		Output: contract.ImageOutput{Path: path, Format: "png", BitDepth: 16, ColorSpace: "sRGB", Quality: .95, TiffCompression: 1, MaxPixel: 2048},
		Policy: a.renderPolicy(), Recipe: recipe, ComputeBackend: a.computeBackend, Preview: preview, PreviewMaxPixel: 2048}
	if a.subjectMask != nil && a.sourceIdentity != nil && a.subjectMask.SourceFingerprint == a.sourceIdentity.Fingerprint && a.subjectMask.RepairDigest == repairDigest(recipe.RepairPatches) {
		job.SubjectMask = &contract.SubjectMaskInput{Path: a.store.MaskPath(a.subjectMask), Sha256: a.subjectMask.SHA256}
	}
	if preview {
		// 沿用 Swift 桌面的顯示編碼；原生運算精度與匯出設定不受影響。
		job.Output.Format, job.Output.BitDepth, job.Output.Quality = "jpeg", 8, .88
		if a.interaction != "" || a.adjustmentPreview.settling {
			job.Policy.FullResolution = false
			job.PreviewMaxPixel, job.Output.MaxPixel = 1024, 1024
		}
	}
	return job
}

func (a *App) preview() {
	a.startPreview(false)
}

func (a *App) startPreview(computeSwitch bool) {
	a.startPreviewMode(computeSwitch, false, 0)
}

func (a *App) startPreviewMode(computeSwitch, live bool, epoch uint64) {
	a.mu.Lock()
	if epoch != 0 && epoch != a.adjustmentPreview.epoch {
		a.mu.Unlock()
		return
	}
	if live {
		if a.interaction == "" && !a.adjustmentPreview.settling {
			a.mu.Unlock()
			return
		}
		if a.adjustmentPreview.activeRevision != 0 && a.adjustmentPreview.activeRevision == a.revision {
			if a.adjustmentPreview.submittedEdit == a.editVersion {
				a.mu.Unlock()
				return
			}
			if a.rendering {
				a.adjustmentPreview.pending = true
				a.mu.Unlock()
				return
			}
		}
	} else {
		a.cancelAdjustmentPreview()
	}
	if a.source == "" || a.saving || a.computing || a.repairing {
		a.mu.Unlock()
		a.state()
		return
	}
	// 排隊中的手勢結束可能重排預覽；切換等待應跟隨最新工作直到完成。
	computeSwitch = computeSwitch || a.switchingComputeBackend()
	if a.cancel != nil {
		a.cancel()
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	a.revision++
	revision := a.revision
	if live {
		a.adjustmentPreview.activeRevision = revision
		a.adjustmentPreview.submittedEdit = a.editVersion
		a.adjustmentPreview.pending = false
	}
	if computeSwitch {
		a.computeSwitchRevision = revision
	}
	a.rendering = true
	a.previewError = nil
	job := a.job("", clone(a.recipes[a.selected]), true)
	thumbnailReady := a.preparePreviewThumbnail()
	a.previewPhase = "render"
	if thumbnailReady != nil {
		a.previewPhase = "thumbnail"
	}
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		// 使用列表同一個工作與快取；先顯示相機縮圖，再進行編輯影像的運算。
		if thumbnailReady != nil {
			select {
			case <-thumbnailReady:
			case <-ctx.Done():
				a.previewDone(revision, "", nil, ctx.Err())
				return
			}
		}
		if err := ctx.Err(); err != nil {
			a.previewDone(revision, "", nil, err)
			return
		}
		a.setPreviewPhase(revision, "render")
		cacheJob := job
		// 連續手勢的中間成品只發布，不反覆雜湊原檔或擠出照片／底片快取。
		cacheKey := ""
		if !live {
			cacheKey, _ = previewResultKey(ctx, cacheJob)
		}
		if cacheKey != "" {
			a.mu.Lock()
			cached, found := a.previewResults.get(cacheKey)
			a.mu.Unlock()
			if found && ctx.Err() == nil {
				a.previewDone(revision, cached.output, cached.result, nil)
				return
			}
		}
		folder, err := os.MkdirTemp("", "filmdevelop-preview-")
		if err != nil {
			a.previewDone(revision, "", nil, err)
			return
		}
		defer os.RemoveAll(folder)
		var result json.RawMessage
		var output string
		if err == nil {
			job.Output.Path = filepath.Join(folder, "output."+job.Output.Format)
			if job.Recipe.DetectSubject && job.SubjectMask == nil {
				maskOutput := filepath.Join(folder, "subject.mask.rgba")
				job.SubjectMaskOutputPath = &maskOutput
			}
			if job.Recipe.DetectSubject {
				a.setPreviewPhase(revision, "subject")
			}
			result, err = a.services.Render(ctx, job, nil)
		}
		if err == nil {
			output, err = previewData(job.Output.Path)
			if err == nil && job.SubjectMaskOutputPath != nil {
				if e := a.adoptRenderedMask(revision, job); e != nil {
					a.migrationProblem("主體遮罩保存", e, "")
				}
			}
		}
		if err == nil && cacheKey != "" {
			// 若原檔在運算途中被替換，不把新內容錯存成舊照片的快取。
			if after, e := previewResultKey(ctx, cacheJob); e == nil && after == cacheKey {
				a.mu.Lock()
				if revision == a.revision {
					a.previewResults.put(cachedPreview{key: cacheKey, output: output, result: result})
				}
				a.mu.Unlock()
			}
		}
		a.previewDone(revision, output, result, err)
	}()
}

func (a *App) setPreviewPhase(revision uint64, phase string) {
	a.mu.Lock()
	if revision != a.revision || !a.rendering || a.previewPhase == phase {
		a.mu.Unlock()
		return
	}
	a.previewPhase = phase
	a.mu.Unlock()
	a.state()
}

func previewData(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return "data:" + http.DetectContentType(data) + ";base64," + base64.StdEncoding.EncodeToString(data), nil
}
func (a *App) previewDone(revision uint64, output string, result json.RawMessage, err error) {
	a.mu.Lock()
	if revision != a.revision {
		a.mu.Unlock()
		return
	}
	a.rendering = false
	a.previewPhase = ""
	a.previewError = err
	if err == nil {
		a.outputPreview = output
		_ = json.Unmarshal(result, &a.renderInfo)
		if source, ok := a.renderInfo["sourceImage"].(string); ok {
			a.sourcePreview = source
		}
		delete(a.renderInfo, "sourceImage")
		if crop, ok := a.renderInfo["cropImage"].(string); ok {
			a.cropPreview = crop
		}
		delete(a.renderInfo, "cropImage")
		var info struct{ SourceWidth, SourceHeight int }
		_ = json.Unmarshal(result, &info)
		a.sourceWidth = info.SourceWidth
		a.sourceHeight = info.SourceHeight
	}
	epoch := a.adjustmentPreview.epoch
	continueLive := a.adjustmentPreview.activeRevision == revision &&
		(a.adjustmentPreview.pending || (a.adjustmentPreview.settling && a.adjustmentPreview.settleReady))
	a.mu.Unlock()
	a.state()
	if continueLive {
		a.enqueueAdjustmentContinuation(epoch, false)
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		a.toast(err)
	}
}

func (a *App) export() error {
	a.mu.Lock()
	if a.source == "" || a.saving || a.computing || a.repairing {
		a.mu.Unlock()
		return errors.New("目前沒有可匯出的照片")
	}
	options := a.exportSettings.saveDialogOptions(a.logicalSourcePath(), a.preferences.ExportDirectory)
	a.mu.Unlock()
	path, err := wruntime.SaveFileDialog(a.ctx, options)
	if err != nil || path == "" {
		return err
	}
	return a.ExportImage(path)
}

// ExportImage 與桌面存檔共用，不允許覆蓋任何已存在的檔案。
func (a *App) ExportImage(path string) error {
	a.mu.Lock()
	if a.source == "" || a.saving || a.computing || a.repairing {
		a.mu.Unlock()
		return errors.New("目前沒有可匯出的照片")
	}
	if !a.exportSettings.matchesExtension(path) {
		a.mu.Unlock()
		return errors.New("輸出副檔名與匯出格式不同，請修正檔名或匯出設定")
	}
	a.invalidatePreview()
	a.saving = true
	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	job := a.job(path, clone(a.recipes[a.selected]), false)
	job.Output = a.exportSettings.output(path)
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		_, err := a.services.Render(ctx, job, nil)
		a.mu.Lock()
		a.saving = false
		a.mu.Unlock()
		a.state()
		if err != nil {
			a.toast(err)
		} else {
			a.toast(fmt.Errorf("已匯出：%s", path))
		}
	}()
	return nil
}
