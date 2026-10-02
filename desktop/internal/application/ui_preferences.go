package application

import (
	"encoding/json"
	"errors"
	"strings"
)

var uiPreferenceKeys = strings.Fields("photoStyle.activeAdjustmentPanel photoStyle.adjustmentMode photoStyle.sidebarGroup.custom photoStyle.sidebarGroup.builtin photoStyle.sidebarCollapsed photoStyle.showHelp photoStyle.appearance photoStyle.thumbnailSize photoStyle.photoDisplayMode photoStyle.styleOrder photoStyle.enabledFilms.v2 photoStyle.enabledStyles photoStyle.enabledExpandedFilms.v1 photoStyle.thumbnailViewport.v1")

func allowedUIPreferences(values object) object {
	result := object{}
	for _, key := range uiPreferenceKeys {
		if v, ok := values[key].(string); ok && len(v) <= 65536 {
			if strings.Contains(key, "enabled") || key == "photoStyle.styleOrder" {
				var ids []string
				if json.Unmarshal([]byte(v), &ids) != nil {
					continue
				}
			}
			choices := map[string][]string{
				"photoStyle.adjustmentMode": {"film", "digital"}, "photoStyle.activeAdjustmentPanel": {"chemistry", "film", "scanner", "frameWatermark", "global", "highlight", "midtone", "shadow"},
				"photoStyle.appearance": {"comfortable", "bright", "dark"}, "photoStyle.thumbnailSize": {"small", "medium", "large", "xlarge"},
			}
			if allowed, ok := choices[key]; ok && !contains(allowed, v) {
				continue
			}
			if strings.HasPrefix(key, "photoStyle.sidebar") || key == "photoStyle.showHelp" {
				if v != "true" && v != "false" {
					continue
				}
			}
			if key == "photoStyle.photoDisplayMode" && !contains([]string{"standard", "time", "rating"}, v) && !strings.HasPrefix(v, "tag:") {
				continue
			}
			result[key] = v
		}
	}
	return result
}

func (a *App) syncUIPreferences(message object) error {
	current := object{}
	if _, err := a.store.LoadState("ui-preferences.json", &current); err != nil {
		a.recoverState("ui-preferences.json", err)
		current = object{}
	}
	if current == nil {
		current = object{}
	}
	valid := allowedUIPreferences(current)
	if len(valid) != len(current) {
		a.migrationProblem("ui-preferences.json", errors.New("已隔離不合法的介面偏好"), "")
		if err := a.store.CommitStates(map[string]any{"ui-preferences.json": valid}); err != nil {
			return err
		}
	}
	current = valid
	if message["initial"] == true {
		// 第一次接線保留這個 Go WebView 原有的選擇；之後 Go 是唯一持久化來源。
		var initialized bool
		_, _ = a.store.LoadState("ui-preferences-initialized.json", &initialized)
		if !initialized {
			if values, ok := message["values"].(object); ok {
				for k, v := range allowedUIPreferences(values) {
					current[k] = v
				}
			}
			if err := a.store.CommitStates(map[string]any{"ui-preferences.json": current, "ui-preferences-initialized.json": true}); err != nil {
				return err
			}
		}
		a.reply("handleUIPreferences", current)
		return nil
	}
	key := stringValue(message, "key")
	if !contains(uiPreferenceKeys, key) {
		return errors.New("介面偏好名稱不符")
	}
	if message["remove"] == true {
		delete(current, key)
	} else {
		values := allowedUIPreferences(object{key: message["value"]})
		value, ok := values[key]
		if !ok {
			return errors.New("介面偏好內容不符")
		}
		current[key] = value
	}
	return a.store.SaveState("ui-preferences.json", current)
}
