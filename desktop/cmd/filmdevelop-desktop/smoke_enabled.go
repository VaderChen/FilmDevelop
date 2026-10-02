//go:build enginesmoke

package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"github.com/VaderChen/FilmDevelop/internal/application"
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/options"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"os"
	"sync"
	"time"
)

//go:embed smoke.js
var smokeScript string

//go:embed navigation_smoke.js
var navigationSmokeScript string

//go:embed editing_smoke.js
var editingSmokeScript string

//go:embed windows_smoke.js
var windowsSmokeScript string

//go:embed migration_smoke.js
var migrationSmokeScript string

//go:embed organization_smoke.js
var organizationSmokeScript string

//go:embed update_notice_smoke.js
var updateNoticeSmokeScript string

// 只存在於 Smoke 建置；正式桌面程式不包含測試指令與任意路徑開檔介面。
func configureSmoke(settings *options.App, app *application.App) {
	app.ConfigureDirectorySmoke(os.Getenv("FILMDEVELOP_SMOKE_DIRECTORY"))
	var once sync.Once
	settings.OnDomReady = func(ctx context.Context) {
		finish := func(report any) {
			once.Do(func() {
				data, _ := json.MarshalIndent(report, "", "  ")
				_ = os.WriteFile(os.Getenv("FILMDEVELOP_SMOKE_REPORT"), data, 0600)
				wruntime.Quit(ctx)
			})
		}
		wruntime.EventsOn(ctx, "filmdevelop:smoke-result", func(args ...interface{}) {
			if len(args) == 1 {
				finish(args[0])
			}
		})
		wruntime.EventsOn(ctx, "filmdevelop:smoke-export", func(...interface{}) {
			if err := app.ExportImage(os.Getenv("FILMDEVELOP_SMOKE_OUTPUT")); err != nil {
				finish(map[string]any{"passed": false, "error": err.Error()})
			}
		})
		wruntime.EventsOn(ctx, "filmdevelop:smoke-reopen", func(...interface{}) {
			go func() {
				if err := app.OpenImage(os.Getenv("FILMDEVELOP_SMOKE_INPUT")); err != nil {
					finish(map[string]any{"passed": false, "error": err.Error()})
				}
			}()
		})
		wruntime.EventsOn(ctx, "filmdevelop:smoke-menu", func(args ...interface{}) {
			if len(args) != 1 {
				return
			}
			label, _ := args[0].(string)
			var click func(*menu.Menu) bool
			click = func(m *menu.Menu) bool {
				for _, item := range m.Items {
					if item.Label == label && item.Click != nil {
						item.Click(&menu.CallbackData{MenuItem: item})
						return true
					}
					if item.SubMenu != nil && click(item.SubMenu) {
						return true
					}
				}
				return false
			}
			if !click(app.Menu()) {
				finish(map[string]any{"passed": false, "error": "找不到系統選單：" + label})
			}
		})
		wruntime.EventsOn(ctx, "filmdevelop:smoke-native-open", func(...interface{}) { app.OpenFileFromOS(os.Getenv("FILMDEVELOP_SMOKE_INPUT")) })
		wruntime.EventsOn(ctx, "filmdevelop:smoke-update-notice", func(...interface{}) { app.RunUpdateNoticeSmoke() })
		wruntime.EventsOn(ctx, "filmdevelop:smoke-empty", func(...interface{}) {
			go func() {
				if err := app.OpenDirectory(os.Getenv("FILMDEVELOP_SMOKE_EMPTY")); err != nil {
					finish(map[string]any{"passed": false, "error": err.Error()})
				}
			}()
		})
		wruntime.EventsOn(ctx, "filmdevelop:smoke-mcp", func(...interface{}) {
			go func() {
				if err := app.RunMCPSmoke(ctx, os.Getenv("FILMDEVELOP_SMOKE_OUTPUT")+".mcp.png"); err != nil {
					finish(map[string]any{"passed": false, "error": err.Error()})
				} else {
					wruntime.EventsEmit(ctx, "filmdevelop:smoke-mcp-done")
				}
			}()
		})
		script := smokeScript
		if os.Getenv("FILMDEVELOP_SMOKE_MIGRATION") == "1" {
			script = migrationSmokeScript
		}
		if os.Getenv("FILMDEVELOP_SMOKE_NAVIGATION") == "1" {
			script = navigationSmokeScript
		}
		if mode := os.Getenv("FILMDEVELOP_SMOKE_EDITING"); mode != "" {
			encoded, _ := json.Marshal(mode)
			script = "window.editingSmokeMode=" + string(encoded) + ";" + editingSmokeScript
		}
		if mode := os.Getenv("FILMDEVELOP_SMOKE_WINDOWS"); mode != "" {
			encoded, _ := json.Marshal(mode)
			script = "window.windowsSmokeMode=" + string(encoded) + ";" + windowsSmokeScript
		}
		if fixture := os.Getenv("FILMDEVELOP_SMOKE_ORGANIZATION"); fixture != "" {
			data, err := os.ReadFile(fixture)
			var expected any
			if err != nil || json.Unmarshal(data, &expected) != nil {
				finish(map[string]any{"passed": false, "error": "分類相容性測試資料無法讀取"})
				return
			}
			encoded, _ := json.Marshal(expected)
			script = "window.organizationSmokeFixture=" + string(encoded) + ";" + organizationSmokeScript
		}
		if os.Getenv("FILMDEVELOP_SMOKE_UPDATE_NOTES") == "1" {
			script = `window.runUpdateNoticeSmoke().then(completed => window.runtime.EventsEmit('filmdevelop:smoke-result', {passed:true, completed})).catch(error => window.runtime.EventsEmit('filmdevelop:smoke-result', {passed:false, error:String(error)}));`
		}
		wruntime.WindowExecJS(ctx, updateNoticeSmokeScript+"\n"+script)
		go func() {
			timer := time.NewTimer(210 * time.Second)
			defer timer.Stop()
			<-timer.C
			finish(map[string]any{"passed": false, "error": "桌面 Smoke 逾時"})
		}()
	}
}
