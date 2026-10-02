package application

import (
	_ "embed"
	"encoding/json"
	"runtime"

	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/menu/keys"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed localization.json
var localizationData []byte

var menuTranslations = func() map[string][]string {
	var data map[string][]string
	if err := json.Unmarshal(localizationData, &data); err != nil {
		panic(err)
	}
	return data
}()

func BuildVersion() string {
	version := currentVersion.Version + " build " + currentVersion.Build
	if runtime.GOOS == "windows" {
		version += " Beta"
	}
	return version
}

// 系統選單與畫面按鈕共用前端的編輯提交，再進入同一條 Go 命令佇列。
func (a *App) Menu() *menu.Menu {
	a.mu.Lock()
	language := a.effectivePromptLanguage()
	a.mu.Unlock()
	label := func(text string) string {
		index, translated := map[string]int{"english": 0, "japanese": 1, "korean": 2}[language]
		if values := menuTranslations[text]; translated && len(values) > index && values[index] != "" {
			return values[index]
		}
		return text
	}
	result := menu.NewMenu()
	if runtime.GOOS == "darwin" {
		result.Append(menu.AppMenu())
	}
	add := func(parent *menu.Menu, title, command, key string, shift bool) {
		var accelerator *keys.Accelerator
		if key != "" {
			accelerator = keys.CmdOrCtrl(key)
			if shift {
				accelerator = keys.Combo(key, keys.CmdOrCtrlKey, keys.ShiftKey)
			}
		}
		parent.AddText(label(title), accelerator, func(*menu.CallbackData) { a.reply("handleDesktopCommand", command) })
	}
	files := result.AddSubmenu(label("檔案"))
	add(files, "選取照片目錄…", "browsePhotoDirectory", "o", true)
	add(files, "開啟照片…", "browseFiles", "o", false)
	files.AddSeparator()
	add(files, "匯出照片…", "exportImage", "s", false)
	files.AddSeparator()
	add(files, "設定…", "settings", ",", false)
	if runtime.GOOS != "darwin" {
		files.AddSeparator()
		files.AddText(label("結束"), keys.CmdOrCtrl("q"), func(*menu.CallbackData) { wruntime.Quit(a.ctx) })
	}
	if runtime.GOOS == "darwin" {
		result.Append(menu.EditMenu())
	}
	photo := result.AddSubmenu(label("照片"))
	add(photo, "AI 輔助計算", "runAI", "return", false)
	photo.AddSeparator()
	add(photo, "上一步", "undoEdit", "", false)
	add(photo, "下一步", "redoEdit", "", false)
	photo.AddSeparator()
	add(photo, "放大", "zoomIn", "+", false)
	add(photo, "縮小", "zoomOut", "-", false)
	add(photo, "符合視窗", "zoomFit", "0", false)
	pages := result.AddSubmenu(label("顯示"))
	add(pages, "工作台", "home", "1", false)
	add(pages, "AI 核心", "ai", "3", false)
	add(pages, "底片", "films", "4", false)
	if runtime.GOOS == "darwin" {
		result.Append(menu.WindowMenu())
	}
	return result
}

func (a *App) updateMenu() {
	if a.ctx != nil && a.emit == nil {
		wruntime.MenuSetApplicationMenu(a.ctx, a.Menu())
	}
}

// Finder 的開檔事件可能先於 WebView 就緒；只在畫面可提交編輯後接手。
func (a *App) OpenFileFromOS(path string) {
	a.mu.Lock()
	a.pendingNativeFile = path
	a.nativeFileID = ""
	ready := a.uiReady
	a.mu.Unlock()
	if ready {
		go func() {
			<-a.ready
			select {
			case a.commands <- object{"action": "requestNativeFile"}:
			case <-a.ctx.Done():
			}
		}()
	}
}

func (a *App) requestNativeFile() {
	a.mu.Lock()
	if a.pendingNativeFile == "" || !a.uiReady || a.nativeFileID != "" || a.dialog != nil || a.rendering || a.saving || a.computing || a.repairing || a.mcpMutating || a.updating {
		a.mu.Unlock()
		return
	}
	a.nativeFileID = identifier()
	id := a.nativeFileID
	a.mu.Unlock()
	a.reply("handleNativeFileOpen", object{"id": id})
}
