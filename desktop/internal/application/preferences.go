package application

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// Preferences 是兩平台共用且可版本化的設定；渲染時產生快照，不修改照片配方。
type Preferences struct {
	Version             int            `json:"version"`
	PromptLanguage      string         `json:"promptLanguage,omitempty"`
	Language            string         `json:"language"`
	ShowAllFilms        bool           `json:"showAllFilms"`
	ExposureExpansion   bool           `json:"exposureExpansionEnabled"`
	ModernExposure      bool           `json:"modernFilmExposureEnabled"`
	HighlightProtection bool           `json:"highlightProtectionEnabled"`
	LensCorrection      bool           `json:"lensCorrectionEnabled"`
	HDR                 bool           `json:"hdrFeatureEnabled"`
	OriginalResolution  bool           `json:"originalResolutionEditing"`
	ComputeBackend      string         `json:"computeBackend"`
	RAWDecoder          string         `json:"rawDecoderBackend"`
	ExportDirectory     string         `json:"defaultExportDirectory"`
	Export              ExportSettings `json:"exportSettings"`
	MCPEnabled          bool           `json:"mcpEnabled"`
}

func defaultPreferences() Preferences {
	return Preferences{Version: 1, Language: "automatic", HighlightProtection: true, LensCorrection: true, HDR: true,
		ComputeBackend: "system", RAWDecoder: "system", Export: defaultExportSettings()}
}
func (a *App) loadPreferences() error {
	p := defaultPreferences()
	var values object
	found, err := a.store.LoadState("preferences.json", &values)
	if err != nil {
		return err
	}
	if found && values["version"] != float64(1) {
		return errors.New("設定版本不支援，原檔已保留")
	}
	damaged := false
	for key, value := range values {
		if key == "exportSettings" {
			if fields, ok := value.(object); ok {
				for k, v := range fields {
					if e := p.Export.update(k, v); e != nil {
						damaged = true
						a.migrationProblem("preferences.json/exportSettings/"+k, e, "")
					}
				}
				continue
			}
		}
		if e := preferenceField(&p, key, value); e != nil {
			damaged = true
			a.migrationProblem("preferences.json/"+key, e, "")
		}
	}
	if damaged {
		if err := a.store.CommitStates(map[string]any{"preferences.json": p}); err != nil {
			return err
		}
	}
	a.preferences = p
	a.exportSettings = p.Export
	a.computeBackend = p.ComputeBackend
	a.rawDecoder = p.RAWDecoder
	return nil
}
func (a *App) savePreferences() error {
	a.preferencesMu.Lock()
	defer a.preferencesMu.Unlock()
	a.mu.Lock()
	p := a.preferences
	p.Export = a.exportSettings
	p.ComputeBackend = a.computeBackend
	p.RAWDecoder = a.rawDecoder
	a.mu.Unlock()
	if err := a.store.SaveState("preferences.json", p); err != nil {
		return err
	}
	a.mu.Lock()
	a.preferences.ComputeBackend = p.ComputeBackend
	a.preferences.RAWDecoder = p.RAWDecoder
	a.mu.Unlock()
	return nil
}
func (a *App) preferencePayload(payload object) {
	data, _ := json.Marshal(a.preferences)
	var p object
	_ = json.Unmarshal(data, &p)
	for k, v := range p {
		if k != "version" && k != "exportSettings" && k != "computeBackend" && k != "rawDecoderBackend" {
			payload[k] = v
		}
	}
	payload["computeBackends"] = a.capabilities["computeBackends"]
	for _, key := range []string{"rawDecoders", "rawExtensions", "rawDecoderLabels", "computeBackendLabels", "rawDecoderMessage", "computeBackendMessage"} {
		payload[key] = a.capabilities[key]
	}
	payload["effectiveRAWDecoderBackend"] = a.renderInfo["rawDecoder"]
	payload["softwareRAWFallback"] = a.renderInfo["softwareRAWFallback"]
	payload["previewOutputSize"] = object{"width": a.renderInfo["outputWidth"], "height": a.renderInfo["outputHeight"]}
	payload["cropAspectRatios"] = a.catalog["cropAspectRatios"]
}
func (a *App) setPreference(action string, message object) error {
	if action == "setLanguage" {
		if message["initial"] == true {
			// 首次畫面只提供系統語言，不用前端暫存覆蓋已保存或遷移的偏好。
			a.mu.Lock()
			a.systemLanguage = promptLanguage(stringValue(message, "systemLanguage"))
			a.mu.Unlock()
			a.updateMenu()
			a.state()
			return nil
		}
		value, _ := message["preference"].(string)
		if value == "" {
			value, _ = message["language"].(string)
		}
		if value == "" {
			value = "automatic"
		}
		if !strings.Contains("|automatic|zh-Hant|zh-Hans|en|ja|ko|traditionalChinese|english|japanese|korean|", "|"+value+"|") {
			return errors.New("語言設定不符")
		}
		a.mu.Lock()
		a.preferences.Language = value
		a.mu.Unlock()
	} else {
		enabled, ok := message["enabled"].(bool)
		if !ok {
			return errors.New("設定必須是布林值")
		}
		a.mu.Lock()
		switch action {
		case "setShowAllFilms":
			a.preferences.ShowAllFilms = enabled
		case "setExposureExpansionEnabled":
			a.preferences.ExposureExpansion = enabled
		case "setModernFilmExposureEnabled":
			a.preferences.ModernExposure = enabled
		case "setHighlightProtectionEnabled":
			a.preferences.HighlightProtection = enabled
		case "setLensCorrectionEnabled":
			a.preferences.LensCorrection = enabled
			a.sourcePreview = ""
		case "setHDRFeatureEnabled":
			a.preferences.HDR = enabled
		case "setOriginalResolutionEditing":
			a.preferences.OriginalResolution = enabled
			a.sourcePreview = ""
		default:
			a.mu.Unlock()
			return errors.New("未知設定")
		}
		a.mu.Unlock()
	}
	if err := a.savePreferences(); err != nil {
		return err
	}
	if action == "setLanguage" || action == "setShowAllFilms" || action == "setExposureExpansionEnabled" {
		if action == "setLanguage" {
			a.updateMenu()
		}
		a.state()
	} else {
		a.preview()
	}
	return nil
}
func (a *App) chooseExportDirectory() error {
	path, err := wruntime.OpenDirectoryDialog(a.ctx, wruntime.OpenDialogOptions{Title: "選取預設匯出目錄"})
	if err != nil || path == "" {
		return err
	}
	a.mu.Lock()
	a.preferences.ExportDirectory = path
	a.mu.Unlock()
	if err = a.savePreferences(); err != nil {
		return err
	}
	a.state()
	return nil
}
func (a *App) renderPolicy() *contract.RenderPolicy {
	p := a.preferences
	return &contract.RenderPolicy{HighlightProtection: p.HighlightProtection, ModernExposure: p.ModernExposure, Hdr: p.HDR, FullResolution: p.OriginalResolution}
}
