package application

import (
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/menu/keys"
	"testing"
)

func TestDesktopMenuUsesEditorCommandsAndPlatformShortcuts(t *testing.T) {
	a := testApp(t)
	commands := map[string]string{}
	a.emit = func(name string, value any) {
		if name != "handleDesktopCommand" {
			t.Fatal(name)
		}
		commands[value.(string)] = value.(string)
	}
	var walk func(*menu.Menu)
	walk = func(m *menu.Menu) {
		for _, item := range m.Items {
			if item.SubMenu != nil {
				walk(item.SubMenu)
				continue
			}
			if item.Click == nil || item.Accelerator == nil || item.Accelerator.Key == "q" {
				continue
			}
			item.Click(&menu.CallbackData{MenuItem: item})
			if len(item.Accelerator.Modifiers) == 0 || item.Accelerator.Modifiers[0] != keys.CmdOrCtrlKey {
				t.Fatal("快捷鍵未對應平台", item.Label)
			}
		}
	}
	walk(a.Menu())
	for _, expected := range []string{"browsePhotoDirectory", "browseFiles", "exportImage", "settings", "runAI", "zoomIn", "zoomOut", "zoomFit", "home", "ai", "films"} {
		if commands[expected] == "" {
			t.Fatal("系統選單遺漏", expected)
		}
	}
}

func TestNativeOpenWaitsForUIAndActiveWork(t *testing.T) {
	a := testApp(t)
	var delivered []string
	a.emit = func(name string, value any) {
		if name == "handleNativeFileOpen" {
			delivered = append(delivered, value.(object)["id"].(string))
		}
	}
	a.OpenFileFromOS("/fixture.png")
	a.requestNativeFile()
	if len(delivered) != 0 {
		t.Fatal("畫面就緒前不得遺失開檔事件")
	}
	a.uiReady = true
	a.computing = true
	a.requestNativeFile()
	if len(delivered) != 0 {
		t.Fatal("AI 工作期間不得切換照片")
	}
	a.computing = false
	a.requestNativeFile()
	a.requestNativeFile()
	if len(delivered) != 1 || a.pendingNativeFile != "/fixture.png" {
		t.Fatal("原生開檔未保留或重複發送")
	}
}
