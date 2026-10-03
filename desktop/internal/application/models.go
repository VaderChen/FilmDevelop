package application

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/models"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	"github.com/VaderChen/FilmDevelop/internal/transfer"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed presets.json
var presetData []byte

type modelPreset struct {
	ID       string          `json:"id"`
	Title    string          `json:"title"`
	Subtitle string          `json:"subtitle"`
	Meta     string          `json:"meta"`
	PageURL  string          `json:"pageURL"`
	Files    []transfer.File `json:"files"`
}

var modelPresets []modelPreset

const unsupportedMLXMessage = "MLX 需要 Apple Silicon；此平台請下載 GGUF 主模型與對應的 mmproj。"

func init() {
	if err := json.Unmarshal(presetData, &modelPresets); err != nil {
		panic(err)
	}
}

type modelSettings struct {
	Version   int    `json:"version"`
	Directory string `json:"directory"`
	Selected  string `json:"selected"`
	Enabled   bool   `json:"enabled"`
}
type repositoryState struct {
	Query, Format, Message string
	Loading                bool
	Results                []models.SearchResult
	Repository             *models.Repository
	Files                  []models.HubFile
	Generation             string
}

func (a *App) loadModels() error {
	root, err := storage.DataDirectory()
	if err != nil {
		return err
	}
	a.managedModels = filepath.Join(root, "models")
	a.modelSettings = modelSettings{Version: 1}
	a.repository = repositoryState{Format: "mlx", Message: "搜尋模型名稱，或貼上 Hugging Face 的 owner/repository。", Results: []models.SearchResult{}}
	if a.capabilities["mlx"] != true {
		a.repository.Format = "gguf"
	}
	found, err := a.store.LoadState("models.json", &a.modelSettings)
	if err != nil {
		return err
	}
	if a.modelSettings.Version != 1 {
		return errors.New("模型設定版本不符")
	}
	if !found && os.Getenv("FILMDEVELOP_DATA_DIR") == "" {
		if path, _ := a.legacySettings["photoStyle.ai.modelDirectory.path"].(string); path != "" {
			a.modelSettings.Directory = path
		}
		a.modelSettings.Selected, _ = a.legacySettings["photoStyle.ai.modelDirectory.selectedModel"].(string)
		a.modelSettings.Enabled, _ = a.legacySettings["photoStyle.ai.enabled"].(bool)
	}
	entries, err := a.scanModelRoots(a.ctx, a.modelSettings.Directory)
	scanErr := err
	a.modelEntries = entries
	if strings.HasPrefix(a.modelSettings.Selected, "installed:") && a.modelSettings.Selected == stringValue(a.legacySettings, "photoStyle.ai.modelDirectory.selectedModel") {
		root, _ := os.UserConfigDir()
		if data, e := readBounded(filepath.Join(root, "PhotoStyleApp", "GGUFModels", "active-model.txt"), 4096); e == nil {
			name := strings.TrimSpace(string(data))
			for _, entry := range entries {
				if entry.ID == "legacy:"+name {
					a.modelSettings.Selected = entry.ID
					break
				}
			}
		}
	}
	a.modelMessage = "模型目錄掃描完成。"
	if scanErr != nil {
		a.modelMessage = scanErr.Error()
	}
	return nil
}
func (a *App) scanModelRoots(ctx context.Context, directory string) ([]models.Entry, error) {
	roots := []struct {
		Path, Prefix string
		Managed      bool
	}{{a.managedModels, "installed:", true}}
	if directory != "" {
		roots = append(roots, struct {
			Path, Prefix string
			Managed      bool
		}{directory, "directory:", false})
	}
	if os.Getenv("FILMDEVELOP_DATA_DIR") == "" {
		root, _ := os.UserConfigDir()
		roots = append(roots, struct {
			Path, Prefix string
			Managed      bool
		}{filepath.Join(root, "PhotoStyleApp", "GGUFModels"), "legacy:", false})
	}
	entries := []models.Entry{}
	var failures []error
	for _, root := range roots {
		if _, err := os.Stat(root.Path); errors.Is(err, os.ErrNotExist) {
			if root.Prefix == "directory:" {
				failures = append(failures, err)
			}
			continue
		}
		found, err := models.Scan(ctx, root.Path)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s：%w", root.Path, err))
			continue
		}
		for _, e := range found {
			e.ID = root.Prefix + e.ID
			e.Managed = root.Managed
			entries = append(entries, e)
		}
	}
	return entries, errors.Join(failures...)
}
func (a *App) activeModel() (models.Entry, bool) {
	if !a.modelSettings.Enabled {
		return models.Entry{}, false
	}
	for _, e := range a.modelEntries {
		if e.ID == a.modelSettings.Selected {
			return e, e.Ready && (e.Format != "mlx" || a.capabilities["mlx"] == true)
		}
	}
	return models.Entry{}, false
}
func (a *App) aiPayload() object {
	active, ready := a.activeModel()
	ready = ready && !a.modelBusy
	choices := []object{}
	fileNames := []string{}
	for _, e := range a.modelEntries {
		enabled := e.Ready
		message := e.Message
		if e.Format == "mlx" && a.capabilities["mlx"] != true {
			enabled = false
			message = unsupportedMLXMessage
		}
		choices = append(choices, object{"id": e.ID, "title": e.Title, "format": e.Format, "ready": enabled, "message": message, "source": "directory"})
		fileNames = append(fileNames, filepath.Base(e.Path))
	}
	presets := []object{}
	for _, p := range modelPresets {
		installed := false
		for _, e := range a.modelEntries {
			if len(p.Files) > 0 && filepath.Base(e.Path) == p.Files[0].Path && e.Ready {
				installed = true
			}
		}
		presets = append(presets, object{"id": p.ID, "title": p.Title, "subtitle": p.Subtitle, "meta": p.Meta, "pageURL": p.PageURL, "fileName": p.Files[0].Path, "installed": installed, "active": ready && filepath.Base(active.Path) == p.Files[0].Path})
	}
	progress := a.modelProgress
	progress.Active = a.modelBusy && a.modelOperation == "download"
	importing := a.modelProgress
	importing.Active = a.modelBusy && a.modelOperation == "import"
	message := a.modelMessage
	if !a.modelSettings.Enabled {
		message = "AI 已關閉；選取模型即可啟用。"
	} else if !ready && !a.modelBusy {
		message = "請選取完整的本機視覺模型。"
	}
	format := active.Format
	if format == "" {
		format = "gguf"
	}
	repository := object{"query": a.repository.Query, "format": a.repository.Format, "loading": a.repository.Loading, "message": a.repository.Message, "results": a.repository.Results, "id": "", "revision": "", "mainFiles": []models.HubFile{}, "projectorFiles": []models.HubFile{}, "files": a.repository.Files, "totalBytes": 0}
	if r := a.repository.Repository; r != nil {
		repository["id"] = r.ID
		repository["revision"] = r.Revision
		repository["mainFiles"] = r.MainFiles()
		repository["projectorFiles"] = r.ProjectorFiles()
		var size int64
		for _, f := range a.repository.Files {
			size += f.Size
		}
		repository["totalBytes"] = size
	}
	activeName := ""
	if active.Path != "" {
		activeName = filepath.Base(active.Path)
	}
	return object{"ready": ready, "busy": a.modelBusy, "status": "local", "message": message, "modelChoices": choices, "modelFiles": fileNames, "presets": presets, "download": progress, "import": importing, "format": format, "mlxAvailable": a.capabilities["mlx"] == true, "mlxMessage": "MLX 由 Apple Silicon 原生核心執行。", "selectedModelID": a.modelSettings.Selected, "modelDirectoryPath": a.modelSettings.Directory, "modelDirectoryScanning": a.modelBusy && a.modelOperation == "scan", "modelDirectoryMessage": a.modelMessage, "usingModelDirectory": strings.HasPrefix(active.ID, "directory:"), "activeModelFileName": activeName, "customModelFileName": activeName, "customActive": ready, "customInstalled": len(a.modelEntries) > 0, "modelDirectory": a.managedModels, "downloadDirectory": a.downloadDirectory(), "repository": repository}
}
func (a *App) downloadDirectory() string {
	if a.modelSettings.Directory != "" {
		return a.modelSettings.Directory
	}
	return a.managedModels
}
func (a *App) saveModelSettings() error {
	a.mu.Lock()
	s := a.modelSettings
	a.mu.Unlock()
	return a.store.SaveState("models.json", s)
}
func (a *App) startModelOperation(operation string, work func(context.Context) error) error {
	a.mu.Lock()
	if a.modelBusy || a.computing {
		a.mu.Unlock()
		return errors.New("模型管理或推論正在進行中")
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.modelCancel = cancel
	a.modelBusy = true
	a.modelOperation = operation
	a.modelProgress = transfer.Progress{Active: true}
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		err := work(ctx)
		a.mu.Lock()
		a.modelBusy = false
		a.modelCancel = nil
		a.modelProgress = transfer.Progress{}
		if err != nil {
			a.modelMessage = err.Error()
		}
		a.mu.Unlock()
		a.state()
		if err != nil && !errors.Is(err, context.Canceled) {
			a.toast(err)
		}
	}()
	return nil
}
func (a *App) modelTransferProgress(p transfer.Progress) {
	a.mu.Lock()
	a.modelProgress = p
	a.mu.Unlock()
	a.state()
}
func (a *App) rescanModels(ctx context.Context, selectPath string) error {
	if selectPath != "" {
		canonical, err := filepath.EvalSymlinks(selectPath)
		if err != nil {
			return err
		}
		selectPath, err = filepath.Abs(canonical)
		if err != nil {
			return err
		}
	}
	a.mu.Lock()
	directory := a.modelSettings.Directory
	a.mu.Unlock()
	entries, scanErr := a.scanModelRoots(ctx, directory)
	if err := ctx.Err(); err != nil {
		return err
	}
	a.mu.Lock()
	a.modelEntries = entries
	a.modelMessage = fmt.Sprintf("已找到 %d 個模型。", len(entries))
	if scanErr != nil {
		a.modelMessage = scanErr.Error()
	}
	if selectPath != "" {
		for _, e := range entries {
			relative, err := filepath.Rel(selectPath, e.Path)
			within := err == nil && !filepath.IsAbs(relative) && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
			if e.Ready && (e.Format != "mlx" || a.capabilities["mlx"] == true) && within {
				a.modelSettings.Selected = e.ID
				a.modelSettings.Enabled = true
				break
			}
		}
	}
	a.mu.Unlock()
	return a.saveModelSettings()
}
func (a *App) handleModels(action string, m object) error {
	switch action {
	case "cancelDownload", "cancelImport", "cancelModelDirectoryScan":
		a.mu.Lock()
		if a.modelCancel != nil {
			a.modelProgress.IsCancelling = true
			a.modelCancel()
		}
		a.mu.Unlock()
		a.state()
		return nil
	case "cancelModelRepositoryQuery":
		a.mu.Lock()
		if a.repositoryCancel != nil {
			a.repositoryCancel()
		}
		a.repository.Generation = identifier()
		a.repository.Loading = false
		a.repository.Message = "已取消查詢。"
		a.mu.Unlock()
		a.state()
		return nil
	case "searchModelRepositories", "inspectModelRepository":
		return a.queryRepository(action == "searchModelRepositories", stringValue(m, "query"), stringValue(m, "format"))
	case "selectModel", "setActiveModel":
		id := stringValue(m, "id")
		name := stringValue(m, "fileName")
		a.mu.Lock()
		if a.modelBusy || a.computing {
			a.mu.Unlock()
			return errors.New("請等待模型作業完成")
		}
		if id == "disabled" || id == "off" || id == "none" {
			a.modelSettings.Enabled = false
			a.modelSettings.Selected = ""
		} else {
			var found *models.Entry
			for i := range a.modelEntries {
				e := &a.modelEntries[i]
				if e.ID == id || (name != "" && filepath.Base(e.Path) == name) {
					found = e
					break
				}
			}
			if found == nil || !found.Ready {
				a.mu.Unlock()
				return errors.New("請選取完整且可使用的模型")
			}
			if found.Format == "mlx" && a.capabilities["mlx"] != true {
				a.mu.Unlock()
				return errors.New("此平台無法使用 MLX，請選取 GGUF")
			}
			a.modelSettings.Selected = found.ID
			a.modelSettings.Enabled = true
		}
		a.mu.Unlock()
		if err := a.saveModelSettings(); err != nil {
			return err
		}
		a.state()
		return nil
	case "openModelDirectory":
		path, err := wruntime.OpenDirectoryDialog(a.ctx, wruntime.OpenDialogOptions{Title: "選取模型目錄", DefaultDirectory: a.modelSettings.Directory})
		if err != nil || path == "" {
			return err
		}
		return a.startModelOperation("scan", func(ctx context.Context) error {
			entries, e := a.scanModelRoots(ctx, path)
			if e != nil {
				return e
			}
			a.mu.Lock()
			if err := ctx.Err(); err != nil {
				a.mu.Unlock()
				return err
			}
			a.modelEntries = entries
			a.modelSettings.Directory = path
			selectedValid := false
			for _, entry := range entries {
				if entry.ID == a.modelSettings.Selected && entry.Ready {
					selectedValid = true
				}
			}
			if !selectedValid {
				for _, entry := range entries {
					if entry.Ready && strings.HasPrefix(entry.ID, "directory:") && (entry.Format != "mlx" || a.capabilities["mlx"] == true) {
						a.modelSettings.Selected = entry.ID
						a.modelSettings.Enabled = true
						break
					}
				}
			}
			a.modelMessage = fmt.Sprintf("已找到 %d 個模型。", len(entries))
			a.mu.Unlock()
			return a.saveModelSettings()
		})
	case "openCustomModel":
		paths, err := wruntime.OpenMultipleFilesDialog(a.ctx, wruntime.OpenDialogOptions{Title: "匯入 GGUF 主模型與 mmproj", Filters: []wruntime.FileFilter{{DisplayName: "GGUF", Pattern: "*.gguf"}}})
		if err != nil || len(paths) == 0 {
			return err
		}
		files := []transfer.File{}
		for _, p := range paths {
			if err = models.ValidateGGUF(p); err != nil {
				return err
			}
			files = append(files, transfer.File{Path: filepath.Base(p), Source: p})
		}
		destination := filepath.Join(a.managedModels, "import-"+identifier())
		return a.startModelOperation("import", func(ctx context.Context) error {
			err := transfer.InstallDirectory(ctx, destination, files, func(stage string) error {
				entries, e := models.Scan(ctx, stage)
				if e != nil {
					return e
				}
				for _, e := range entries {
					if e.Ready {
						return nil
					}
				}
				return errors.New("請同時選取主模型及對應的 mmproj")
			}, a.modelTransferProgress)
			if err != nil {
				return err
			}
			return a.rescanModels(ctx, destination)
		})
	case "downloadPreset":
		id := stringValue(m, "id")
		var preset *modelPreset
		for i := range modelPresets {
			if modelPresets[i].ID == id {
				preset = &modelPresets[i]
			}
		}
		if preset == nil {
			return errors.New("模型預設不存在")
		}
		destination := filepath.Join(a.managedModels, preset.ID+"-"+identifier()[:8])
		return a.startModelOperation("download", func(ctx context.Context) error {
			files := []transfer.File{}
			cache := map[string]models.Repository{}
			for _, f := range preset.Files {
				raw := strings.TrimPrefix(f.URL, models.Hub+"/")
				parts := strings.SplitN(raw, "/resolve/main/", 2)
				if len(parts) != 2 {
					return errors.New("模型預設網址不符")
				}
				repo, ok := cache[parts[0]]
				if !ok {
					var e error
					repo, e = models.Inspect(ctx, transfer.ReadJSON, parts[0])
					if e != nil {
						return e
					}
					cache[parts[0]] = repo
				}
				wanted := strings.Split(parts[1], "?")[0]
				found := false
				for _, candidate := range repo.Files {
					if candidate.Path == wanted {
						files = append(files, transfer.File{Path: f.Path, URL: candidate.URL, Size: candidate.Size, SHA256: candidate.SHA256})
						found = true
						break
					}
				}
				if !found {
					return fmt.Errorf("模型檔案不存在：%s", wanted)
				}
			}
			return a.installModels(ctx, destination, files)
		})
	case "downloadModelRepository":
		a.mu.Lock()
		r := clone(a.repository.Repository)
		format := a.repository.Format
		files := clone(a.repository.Files)
		parent := a.downloadDirectory()
		supported := format != "mlx" || a.capabilities["mlx"] == true
		a.mu.Unlock()
		if !supported {
			return errors.New(unsupportedMLXMessage)
		}
		if r == nil {
			return errors.New("請先查詢模型 repository")
		}
		if format == "gguf" {
			var err error
			files, err = r.GGUFPlan(stringValue(m, "mainPath"), stringValue(m, "projectorPath"))
			if err != nil {
				return err
			}
		}
		paths := []string{}
		assets := []transfer.File{}
		for _, f := range files {
			paths = append(paths, f.Path)
			assets = append(assets, transfer.File{Path: f.Path, URL: f.URL, Size: f.Size, SHA256: f.SHA256})
		}
		sort.Strings(paths)
		digest := sha256.Sum256([]byte(r.ID + "@" + r.Revision + ":" + strings.Join(paths, "|")))
		name := strings.ReplaceAll(r.ID, "/", "--") + "-" + hex.EncodeToString(digest[:6])
		destination := filepath.Join(parent, name)
		return a.startModelOperation("download", func(ctx context.Context) error { return a.installModels(ctx, destination, assets) })
	case "deletePreset":
		id := stringValue(m, "id")
		var selected models.Entry
		a.mu.Lock()
		for _, p := range modelPresets {
			if p.ID == id {
				for _, e := range a.modelEntries {
					if e.Managed && filepath.Base(e.Path) == p.Files[0].Path {
						selected = e
						break
					}
				}
			}
		}
		a.mu.Unlock()
		if selected.Path == "" {
			return errors.New("此模型由外部目錄管理，請使用檔案管理員移除")
		}
		relative, err := filepath.Rel(a.managedModels, selected.Path)
		if err != nil || strings.HasPrefix(relative, "..") {
			return errors.New("模型不在應用程式管理範圍")
		}
		folder := filepath.Join(a.managedModels, strings.Split(relative, string(filepath.Separator))[0])
		return a.showDialog("刪除已下載模型", selected.Title, "", []dialogChoice{{ID: "delete", Label: "刪除模型", Role: "destructive"}}, func(string) error {
			return a.startModelOperation("delete", func(ctx context.Context) error {
				if err := os.RemoveAll(folder); err != nil {
					return err
				}
				return a.rescanModels(ctx, "")
			})
		}, dialogOptions{LiteralDetail: true})
	}
	return errors.New("未知模型操作")
}
func (a *App) installModels(ctx context.Context, destination string, files []transfer.File) error {
	err := transfer.InstallDirectory(ctx, destination, files, func(stage string) error {
		entries, e := models.Scan(ctx, stage)
		if e != nil {
			return e
		}
		if len(entries) == 0 {
			return errors.New("下載中沒有視覺模型")
		}
		for _, e := range entries {
			if !e.Ready {
				return errors.New(e.Message)
			}
		}
		return nil
	}, a.modelTransferProgress)
	if err != nil {
		return err
	}
	return a.rescanModels(ctx, destination)
}
func (a *App) queryRepository(search bool, query, format string) error {
	if format != "gguf" && format != "mlx" {
		return errors.New("模型格式不符")
	}
	a.mu.Lock()
	if format == "mlx" && a.capabilities["mlx"] != true {
		a.mu.Unlock()
		return errors.New(unsupportedMLXMessage)
	}
	if a.repositoryCancel != nil {
		a.repositoryCancel()
	}
	ctx, cancel := context.WithTimeout(a.ctx, 45*time.Second)
	a.repositoryCancel = cancel
	id := identifier()
	a.repository = repositoryState{Query: query, Format: format, Loading: true, Message: "正在查詢 Hugging Face…", Generation: id, Results: []models.SearchResult{}}
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		state := repositoryState{Query: query, Format: format, Generation: id, Results: []models.SearchResult{}}
		var err error
		if search {
			state.Results, err = models.Search(ctx, transfer.ReadJSON, query, format)
			state.Message = "選取模型以查看檔案。"
		} else {
			var repo models.Repository
			repo, err = models.Inspect(ctx, transfer.ReadJSON, query)
			if err == nil {
				state.Repository = &repo
				if format == "mlx" {
					state.Files, err = repo.MLXPlan(ctx, transfer.ReadJSON)
				}
			}
			state.Message = "確認模型檔案後可下載並使用。"
		}
		if err != nil {
			state.Message = err.Error()
		}
		a.mu.Lock()
		if a.repository.Generation == id {
			a.repository = state
		}
		a.mu.Unlock()
		a.state()
	}()
	return nil
}
