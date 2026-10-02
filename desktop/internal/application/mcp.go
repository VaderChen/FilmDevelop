package application

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/mcp"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type mcpRequest struct {
	ctx       context.Context
	name      string
	arguments object
	reply     chan mcpReply
}
type mcpReply struct {
	value object
	err   error
}

func (a *App) mcpDefinitions() []object {
	stringField := object{"type": "string"}
	enum := func(values ...any) object { return object{"type": "string", "enum": values} }
	definitions := []object{}
	add := func(name, description string, read bool, properties object, required ...string) {
		if properties == nil {
			properties = object{}
		}
		definitions = append(definitions, object{"name": name, "description": description, "inputSchema": object{"type": "object", "properties": properties, "required": required, "additionalProperties": false}, "annotations": object{"readOnlyHint": read, "destructiveHint": name == "export_image", "openWorldHint": false}})
	}
	add("get_state", "讀取目前照片、調整及處理進度。", true, nil)
	add("list_styles", "列出可套用的底片與自訂風格。", true, nil)
	add("get_preview", "取得目前處理結果的預覽影像。", true, nil)
	add("open_image", "開啟本機照片並同步介面。", false, object{"path": stringField}, "path")
	add("set_style", "選取底片或自訂底片。", false, object{"style": stringField}, "style")
	add("update_adjustments", "依共用編輯契約驗證整批參數，再套用並同步預覽。", false, object{"changes": object{"type": "object", "properties": a.services.EditorProperties(), "additionalProperties": false, "minProperties": 1}}, "changes")
	add("import_color_calibration", "匯入量測色彩校準 JSON。", false, object{"path": stringField}, "path")
	add("clear_color_calibration", "移除目前照片的色彩校準。", false, nil)
	add("run_ai", "啟動本機 AI 分析；prompt 與 language 僅對本次生效。", false, object{"prompt": object{"type": "string", "minLength": 1, "maxLength": 8000}, "language": enum("traditionalChinese", "english", "japanese", "korean")})
	add("cancel_ai", "取消目前 AI 分析，等待工作程序清理。", false, nil)
	add("export_image", "原尺寸匯出；預設拒絕覆寫，格式與色深必須相容。", false, object{"path": stringField, "format": enum("png", "jpeg", "webp", "tiff"), "bitDepth": object{"type": "integer", "enum": []any{float64(8), float64(16)}}, "overwrite": object{"type": "boolean"}}, "path")
	add("show_page", "切換桌面頁面。", false, object{"page": enum("home", "styles", "films", "ai", "settings")}, "page")
	return definitions
}
func (a *App) startMCP() error {
	root, err := storage.DataDirectory()
	if err != nil {
		return err
	}
	server, err := mcp.Start(filepath.Join(root, "MCP"), "127.0.0.1:8765", a.mcpDefinitions(), a.handleMCP)
	a.mu.Lock()
	defer a.mu.Unlock()
	if err != nil {
		a.mcpMessage = err.Error()
		return err
	}
	a.mcpServer = server
	a.mcpMessage = "運作中（僅限本機）"
	return nil
}
func (a *App) mcpPayload() object {
	p := object{"enabled": a.preferences.MCPEnabled, "running": a.mcpServer != nil, "status": a.mcpMessage, "endpoint": "http://127.0.0.1:8765/mcp", "connectionFile": ""}
	path := filepath.Join(a.store.Root(), "MCP", "connection.json")
	if a.mcpServer != nil {
		path = a.mcpServer.ConnectionFile
	}
	// 設定檔可在伺服器停用後保留；依實際檔案決定是否提供顯示路徑。
	if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
		p["connectionFile"] = path
	}
	return p
}
func (a *App) setMCP(message object) error {
	enabled, ok := message["enabled"].(bool)
	if !ok {
		return errors.New("MCP 開關格式錯誤")
	}
	a.mu.Lock()
	server := a.mcpServer
	a.mcpServer = nil
	a.preferences.MCPEnabled = enabled
	a.mcpMessage = "已停用"
	a.mu.Unlock()
	if server != nil {
		server.Close()
	}
	err := a.savePreferences()
	if err == nil && enabled {
		err = a.startMCP()
	}
	a.state()
	return err
}
func (a *App) handleMCP(ctx context.Context, name string, args object) (object, error) {
	switch name {
	case "get_state":
		return mcp.Text(a.mcpState()), nil
	case "list_styles":
		a.mu.Lock()
		styles := a.stylePayloads()
		a.mu.Unlock()
		return mcp.Text(object{"styles": styles}), nil
	case "cancel_ai":
		a.mu.Lock()
		if a.computing && a.cancel != nil {
			a.cancel()
		}
		a.mu.Unlock()
		return mcp.Text(a.mcpState()), nil
	case "get_preview":
		if err := a.waitPreview(ctx); err != nil {
			return nil, err
		}
		a.mu.Lock()
		value := a.outputPreview
		a.mu.Unlock()
		parts := strings.SplitN(value, ",", 2)
		if len(parts) != 2 {
			return nil, errors.New("尚無預覽")
		}
		mime := strings.TrimSuffix(strings.TrimPrefix(parts[0], "data:"), ";base64")
		return object{"content": []object{{"type": "image", "mimeType": mime, "data": parts[1]}}, "isError": false}, nil
	}
	request := &mcpRequest{ctx: ctx, name: name, arguments: args, reply: make(chan mcpReply, 1)}
	select {
	case a.commands <- object{"action": "mcpRequest", "request": request}:
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-a.ctx.Done():
		return nil, a.ctx.Err()
	}
	select {
	case result := <-request.reply:
		return result.value, result.err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-a.ctx.Done():
		return nil, a.ctx.Err()
	}
}
func (a *App) beginMCP(request *mcpRequest) {
	a.mu.Lock()
	busy := a.mcpMutating || a.saving || a.computing || a.repairing || a.dialog != nil || a.directoryScanning || a.updating || a.switchingComputeBackend()
	if busy || request.ctx.Err() != nil {
		a.mu.Unlock()
		request.reply <- mcpReply{err: errors.New("目前有照片處理或對話框進行中")}
		return
	}
	a.mcpMutating = true
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		value, err := a.performMCP(request.ctx, request.name, request.arguments)
		a.mu.Lock()
		a.mcpMutating = false
		a.mu.Unlock()
		a.state()
		request.reply <- mcpReply{value, err}
	}()
}
func (a *App) performMCP(ctx context.Context, name string, args object) (object, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var err error
	result := object{}
	wait := false
	path := stringValue(args, "path")
	if path != "" && (!filepath.IsAbs(path) || strings.ContainsRune(path, 0)) {
		return nil, errors.New("請提供絕對檔案路徑")
	}
	switch name {
	case "open_image":
		err = a.OpenImage(path)
		wait = true
	case "set_style":
		err = a.selectStyle(stringValue(args, "style"))
		if err == nil {
			a.preview()
		}
		wait = true
	case "update_adjustments":
		changes := args["changes"].(object)
		keys := []string{}
		for k := range changes {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		list := []object{}
		for _, k := range keys {
			list = append(list, object{"key": k, "value": changes[k]})
		}
		a.mu.Lock()
		generation := a.generation
		a.mu.Unlock()
		err = a.update(object{"adjustments": list, "photoGeneration": generation})
		if err == nil {
			a.preview()
		}
		wait = true
	case "import_color_calibration", "clear_color_calibration":
		var data []byte
		if name == "import_color_calibration" {
			data, err = readBounded(path, 64*1024)
		}
		if err == nil {
			var calibration any
			if len(data) > 0 {
				err = json.Unmarshal(data, &calibration)
			}
			if err == nil {
				a.mu.Lock()
				base := a.recipes[a.selected]
				fields := recipeFields(base)
				if calibration == nil {
					delete(fields, "colorCalibration")
				} else {
					fields["colorCalibration"] = calibration
				}
				var normalized contract.Recipe
				normalized, err = a.services.NormalizeRecipe(withFields(base, fields))
				if err == nil {
					a.pushHistory()
					a.recipes[a.selected] = normalized
					err = a.refreshUI()
				}
				a.mu.Unlock()
				if err == nil {
					a.preview()
				}
			}
		}
		wait = true
	case "run_ai":
		err = a.applyAIWith(stringValue(args, "prompt"), stringValue(args, "language"))
	case "show_page":
		page := stringValue(args, "page")
		if page == "films" {
			page = "styles"
		}
		a.reply("handleMCPPage", object{"page": page})
	case "export_image":
		result, err = a.mcpExport(ctx, args)
	default:
		err = errors.New("不支援的 MCP 工具")
	}
	if err == nil && wait {
		err = a.persist()
		if err == nil {
			err = a.waitPreview(ctx)
		}
		if err == nil {
			err = a.flushMCPUI(ctx)
		}
	}
	if err != nil {
		return nil, err
	}
	result["state"] = a.mcpState()
	return mcp.Text(result), nil
}
func (a *App) mcpState() object {
	a.mu.Lock()
	defer a.mu.Unlock()
	_, ready := a.activeModel()
	return clone(object{"hasImage": a.source != "", "fileName": filepath.Base(a.source), "selectedStyle": a.selected, "adjustment": a.ui[a.selected], "imageSize": object{"width": a.sourceWidth, "height": a.sourceHeight}, "outputSize": object{"width": a.renderInfo["outputWidth"], "height": a.renderInfo["outputHeight"]}, "isRenderingPreview": a.previewBusy(), "isComputing": a.computing, "isRepairingImage": a.repairing, "isSavingImage": a.saving, "computationStep": a.computationStep, "aiReady": ready, "uiReady": true, "lastMessage": a.lastMessage, "lastExportedPath": a.lastExportedPath})
}
func (a *App) waitPreview(ctx context.Context) error {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		a.mu.Lock()
		busy := a.previewBusy()
		err := a.previewError
		a.mu.Unlock()
		if !busy {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-a.ctx.Done():
			return a.ctx.Err()
		case <-ticker.C:
		}
	}
}
func (a *App) flushMCPUI(ctx context.Context) error {
	a.mu.Lock()
	id := identifier()
	ch := make(chan struct{})
	a.mcpFlushID = id
	a.mcpFlush = ch
	a.mu.Unlock()
	a.state()
	a.reply("handleMCPFlush", object{"id": id})
	select {
	case <-ch:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-a.ctx.Done():
		return a.ctx.Err()
	}
}
func (a *App) mcpExport(ctx context.Context, args object) (object, error) {
	path := stringValue(args, "path")
	format := stringValue(args, "format")
	if format == "" {
		format = strings.TrimPrefix(strings.ToLower(filepath.Ext(path)), ".")
		if format == "jpg" {
			format = "jpeg"
		}
		if format == "tif" {
			format = "tiff"
		}
	}
	settings := defaultExportSettings()
	settings.Format = format
	settings.PNGDepth = 8
	if depth, ok := args["bitDepth"].(float64); ok {
		if (format == "jpeg" || format == "webp") && depth != 8 {
			return nil, errors.New("此格式僅支援 8 bit")
		}
		settings.PNGDepth = int(depth)
		settings.TIFFDepth = int(depth)
	}
	if err := settings.update("format", format); err != nil {
		return nil, err
	}
	if !settings.matchesExtension(path) {
		return nil, errors.New("匯出格式與副檔名不符")
	}
	a.mu.Lock()
	if a.source == "" {
		a.mu.Unlock()
		return nil, errors.New("請先選取照片")
	}
	source := a.source
	settings.WriteExif = a.exportSettings.WriteExif
	job := a.job(path, clone(a.recipes[a.selected]), false)
	job.Output = settings.output(path)
	a.saving = true
	a.mu.Unlock()
	a.state()
	defer func() { a.mu.Lock(); a.saving = false; a.mu.Unlock() }()
	canonical, _ := filepath.EvalSymlinks(path)
	if canonical == source || filepath.Clean(path) == source {
		return nil, errors.New("不得覆寫來源照片")
	}
	overwrite, _ := args["overwrite"].(bool)
	var old os.FileInfo
	if info, e := os.Stat(path); e == nil {
		if !overwrite {
			return nil, errors.New("輸出已存在")
		}
		if !info.Mode().IsRegular() {
			return nil, errors.New("輸出不是一般檔案")
		}
		old = info
	} else if !errors.Is(e, os.ErrNotExist) {
		return nil, e
	}
	target := path
	if old != nil {
		dir, e := os.MkdirTemp(filepath.Dir(path), ".filmdevelop-export-")
		if e != nil {
			return nil, e
		}
		defer os.RemoveAll(dir)
		target = filepath.Join(dir, filepath.Base(path))
		job.Output.Path = target
	}
	data, err := a.services.Render(ctx, job, nil)
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if old != nil {
		current, e := os.Stat(path)
		if e != nil || !os.SameFile(old, current) || old.Size() != current.Size() || !old.ModTime().Equal(current.ModTime()) {
			return nil, errors.New("目的檔案已被其他操作修改")
		}
		if err = os.Rename(target, path); err != nil {
			return nil, err
		}
	}
	var result object
	_ = json.Unmarshal(data, &result)
	result["path"] = path
	result["format"] = format
	result["bitDepth"] = job.Output.BitDepth
	a.mu.Lock()
	a.lastExportedPath = path
	a.mu.Unlock()
	return result, nil
}
func (a *App) copyMCPConfiguration() error {
	a.mu.Lock()
	server := a.mcpServer
	a.mu.Unlock()
	if server == nil {
		return errors.New("請先啟用 MCP")
	}
	data, err := readBounded(server.ConnectionFile, 64*1024)
	if err != nil {
		return err
	}
	return wruntime.ClipboardSetText(a.ctx, string(data))
}
