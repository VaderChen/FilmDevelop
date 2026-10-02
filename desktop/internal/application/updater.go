package application

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/storage"
	"github.com/VaderChen/FilmDevelop/internal/transfer"
	"github.com/VaderChen/FilmDevelop/internal/updater"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed version.json
var versionData []byte
var currentVersion updater.Version

func init() {
	if err := json.Unmarshal(versionData, &currentVersion); err != nil {
		panic(err)
	}
}

type updateState struct {
	Version      int    `json:"version"`
	Last         string `json:"last"`
	Pending      string `json:"pending"`
	Acknowledged string `json:"acknowledged"`
}

func (a *App) loadUpdates() error {
	var state updateState
	found, err := a.store.LoadState("updates.json", &state)
	if err != nil {
		return err
	}
	if found && state.Version != 1 {
		return errors.New("更新紀錄版本不符")
	}
	state.Version = 1
	previous, e := updater.Parse(state.Last)
	if e == nil && currentVersion.After(previous) {
		state.Pending = currentVersion.Tag()
	}
	if err = updater.Confirm(os.Args, currentVersion); err != nil {
		return err
	}
	for _, arg := range os.Args {
		if arg == "--finish-update" {
			state.Pending = currentVersion.Tag()
		}
	}
	state.Last = currentVersion.Tag()
	a.updateState = state
	return a.store.SaveState("updates.json", state)
}
func (a *App) checkUpdate(manual bool) error {
	a.mu.Lock()
	if a.checkingUpdate || a.updating {
		a.mu.Unlock()
		if manual {
			a.toast(errors.New("更新檢查或下載正在進行"))
		}
		return nil
	}
	a.checkingUpdate = true
	a.mu.Unlock()
	if manual {
		a.toast(errors.New("正在檢查 GitHub 最新版本"))
	}
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		ctx, cancel := context.WithTimeout(a.ctx, 35*time.Second)
		defer cancel()
		release, err := updater.Latest(ctx)
		var asset *updater.Asset
		var version updater.Version
		if err == nil {
			var identifier string
			identifier, err = updater.InstalledIdentifier(ctx)
			if err == nil {
				version, asset, err = release.SelectForBundle(currentVersion, runtime.GOOS, identifier)
			}
		}
		a.mu.Lock()
		a.checkingUpdate = false
		a.mu.Unlock()
		if err != nil {
			if manual && a.ctx.Err() == nil {
				a.toast(err)
			}
			return
		}
		if asset == nil {
			if manual {
				a.toast(fmt.Errorf("目前已是最新版本：%s", BuildVersion()))
			}
			return
		}
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			a.mu.Lock()
			busy := a.saving || a.computing || a.repairing || a.mcpMutating || a.modelBusy || a.dialog != nil || a.updating
			a.mu.Unlock()
			if !busy {
				break
			}
			select {
			case <-a.ctx.Done():
				return
			case <-ticker.C:
			}
		}
		_ = a.showDialog("有新版本可更新", fmt.Sprintf("目前：%s\n新版：%s build %s\n\n將下載並驗證 %s，保存照片調整後更新 App。", BuildVersion(), version.Version, version.Build, asset.Name), "", []dialogChoice{{ID: "install", Label: "下載並更新"}}, func(string) error { return a.downloadUpdate(*asset, version) })
	}()
	return nil
}
func (a *App) downloadUpdate(asset updater.Asset, version updater.Version) error {
	if err := a.persist(); err != nil {
		return err
	}
	a.mu.Lock()
	if a.saving || a.computing || a.repairing || a.modelBusy || a.mcpMutating || a.updating {
		a.mu.Unlock()
		return errors.New("請先等待目前工作完成")
	}
	if a.cancel != nil {
		a.cancel()
	}
	a.revision++
	a.rendering = false
	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	a.updating = true
	a.mu.Unlock()
	a.state()
	if err := a.showDialog("正在下載更新", asset.Name, "", []dialogChoice{{ID: "cancel", Label: "取消下載"}}, func(string) error { cancel(); return nil }); err != nil {
		cancel()
		a.mu.Lock()
		a.updating = false
		a.mu.Unlock()
		a.state()
		return err
	}
	a.mu.Lock()
	if a.dialog != nil {
		a.dialog.Cancel = cancel
	}
	dialogID := a.dialog.ID
	a.mu.Unlock()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		root, err := storage.DataDirectory()
		destination := ""
		var prepared *updater.Prepared
		if err == nil {
			destination = filepath.Join(root, "updates", identifier())
			err = updater.Download(ctx, destination, asset, func(p transfer.Progress) {
				a.reply("handleHostProgress", object{"id": dialogID, "detail": fmt.Sprintf("%s\n%d%%（%d / %d MB）", asset.Name, p.Percent, p.Received/1024/1024, p.Total/1024/1024)})
			})
		}
		if err == nil {
			a.reply("handleHostProgress", object{"id": dialogID, "detail": "正在驗證安裝包與平台引擎…"})
			prepared, err = updater.Prepare(ctx, filepath.Join(destination, asset.Name), version)
		}
		if err == nil {
			err = ctx.Err()
		}
		if err == nil {
			err = a.persist()
		}
		if err == nil {
			err = prepared.Launch()
		}
		a.mu.Lock()
		a.updating = false
		if a.dialog != nil && a.dialog.ID == dialogID {
			a.dialog = nil
		}
		a.mu.Unlock()
		a.reply("handleHostProgress", object{"id": dialogID, "close": true})
		if err != nil {
			if prepared != nil {
				prepared.Discard()
			}
			if destination != "" {
				_ = os.RemoveAll(destination)
			}
			if ctx.Err() == nil {
				a.toast(err)
			}
			a.state()
			return
		}
		// 安裝工具接手後保留下載檔，Windows 安裝程序仍會使用它。
		wruntime.Quit(a.ctx)
	}()
	return nil
}
func (a *App) acknowledgeUpdate(message object) error {
	tag := stringValue(message, "tag")
	a.mu.Lock()
	if tag != currentVersion.Tag() || tag != a.updateState.Pending {
		a.mu.Unlock()
		return errors.New("更新通知版本不符")
	}
	a.updateState.Acknowledged = tag
	a.updateState.Pending = ""
	state := a.updateState
	a.mu.Unlock()
	return a.store.SaveState("updates.json", state)
}
func (a *App) startUpdateCheck() {
	if os.Getenv("FILMDEVELOP_DATA_DIR") != "" {
		return
	}
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		timer := time.NewTimer(3 * time.Second)
		defer timer.Stop()
		select {
		case <-a.ctx.Done():
			return
		case <-timer.C:
		}
		a.mu.Lock()
		pending := a.updateState.Pending
		ack := a.updateState.Acknowledged
		a.mu.Unlock()
		if pending == currentVersion.Tag() && pending != ack {
			a.reply("handleUpdateComplete", object{"tag": pending, "version": BuildVersion(), "highlights": []string{"Go 統一管理桌面介面、照片編輯與模型；平台引擎負責影像及 AI 運算。"}})
		}
		select {
		case a.commands <- object{"action": "checkAppUpdate", "automatic": true}:
		case <-a.ctx.Done():
		}
	}()
}
