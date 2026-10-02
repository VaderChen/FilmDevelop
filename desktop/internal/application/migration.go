package application

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type migrationReceipt struct {
	SourceHash  string `json:"sourceHash"`
	Disposition string `json:"disposition"`
}
type migrationLedger struct {
	Version int                         `json:"version"`
	Items   map[string]migrationReceipt `json:"items"`
}
type migrationIssue struct {
	Source   string `json:"source"`
	Message  string `json:"message"`
	Recovery string `json:"recovery,omitempty"`
}

func (a *App) migrationProblem(source string, err error, recovery string) {
	if err == nil {
		return
	}
	a.migrationMu.Lock()
	defer a.migrationMu.Unlock()
	issue := migrationIssue{source, err.Error(), recovery}
	for _, old := range a.migrationIssues {
		if old == issue {
			return
		}
	}
	a.migrationIssues = append(a.migrationIssues, issue)
	_ = a.store.SaveState("migration-issues.json", a.migrationIssues)
}

// 區分可恢復的使用者資料錯誤與無法載入程式目錄的致命錯誤。
func (a *App) recoverState(name string, err error) {
	if err == nil {
		return
	}
	backup, backupErr := a.store.QuarantineState(name)
	a.migrationProblem(name, errors.Join(err, backupErr), backup)
}

func sourceHash(value any) string {
	data, _ := json.Marshal(value)
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// 收據逐欄記錄，包含保留新版的決策；刪除後也不會再次灌回舊值。
// 缺少或壞掉的來源不建立完成收據，下次啟動可重試。
func (a *App) mergeLegacyState(name string, incoming object) error {
	if len(incoming) == 0 {
		return nil
	}
	ledger := migrationLedger{Version: 1, Items: map[string]migrationReceipt{}}
	if _, err := a.store.LoadState("migrations.json", &ledger); err != nil {
		return err
	}
	if ledger.Version != 1 || ledger.Items == nil {
		return errors.New("移轉紀錄版本不符")
	}
	current := object{}
	found, err := a.store.LoadState(name, &current)
	if err != nil {
		return err
	}
	explicitEmpty := found && len(current) == 0 && (name == "prompts.json" || name == "ui-preferences.json")
	if current == nil {
		current = object{}
	}
	changed := false
	var merge func(object, object, string)
	merge = func(dst, src object, prefix string) {
		for key, value := range src {
			if key == "version" {
				if _, ok := dst[key]; !ok {
					dst[key] = value
				}
				continue
			}
			id := name + ":" + prefix + key
			if nested, ok := value.(object); ok {
				if target, exists := dst[key]; exists {
					if child, ok := target.(object); ok {
						merge(child, nested, prefix+key+"/")
						continue
					}
				} else {
					child := object{}
					merge(child, nested, prefix+key+"/")
					if len(child) > 0 {
						dst[key] = child
					}
					continue
				}
			}
			if _, done := ledger.Items[id]; done {
				continue
			}
			disposition := "保留新版"
			if _, exists := dst[key]; !exists && !explicitEmpty {
				dst[key] = value
				disposition = "已匯入"
			}
			ledger.Items[id] = migrationReceipt{sourceHash(value), disposition}
			changed = true
		}
	}
	merge(current, incoming, "")
	if !changed {
		return nil
	}
	return a.store.CommitStates(map[string]any{name: current, "migrations.json": ledger})
}

func (a *App) migrateLegacyValues() error {
	v := a.legacySettings
	if len(v) == 0 {
		return nil
	}
	if paths, ok := v["resolvedPaths"].([]any); ok {
		aliases := object{}
		for _, raw := range paths {
			if value, ok := raw.(object); ok && stringValue(value, "from") != "" && stringValue(value, "to") != "" {
				aliases[sourceHash(value)] = value
			}
		}
		if err := a.mergeLegacyState("path-aliases.json", aliases); err != nil {
			return err
		}
	}
	p := object{"version": 1}
	keys := map[string]string{
		"interfaceLanguage.v1": "language", "promptLanguage.v1": "promptLanguage", "showAllFilms.v1": "showAllFilms",
		"exposureExpansionEnabled.v1": "exposureExpansionEnabled", "modernFilmExposureEnabled.v1": "modernFilmExposureEnabled",
		"highlightProtectionEnabled.v1": "highlightProtectionEnabled", "lensCorrectionEnabled.v1": "lensCorrectionEnabled",
		"hdrFeatureEnabled.v1": "hdrFeatureEnabled", "originalResolutionEditing.v2": "originalResolutionEditing",
		"computeBackend.v1": "computeBackend", "rawDecoderBackend.v1": "rawDecoderBackend", "mcpEnabled.v1": "mcpEnabled",
		"defaultExportDirectory.path.v1": "defaultExportDirectory",
	}
	for old, next := range keys {
		if value, ok := v[old]; ok {
			probe := defaultPreferences()
			if e := preferenceField(&probe, next, value); e != nil {
				a.migrationProblem(old, e, "")
				continue
			}
			p[next] = value
		}
	}
	export := defaultExportSettings()
	e := object{}
	for _, key := range []string{"maxPixel", "colorSpace", "jpegQuality", "webpQuality", "webpLossless", "tiffCompression"} {
		if value, ok := v["photoExport."+key]; ok {
			if err := export.update(key, value); err != nil {
				a.migrationProblem("photoExport."+key, err, "")
				continue
			}
			e[key] = value
		}
	}
	if value, ok := v["photoExportFormat.v1"]; ok {
		if err := export.update("format", value); err == nil {
			e["format"] = value
		} else {
			a.migrationProblem("photoExportFormat.v1", err, "")
		}
	}
	if depths, ok := v["photoExportBitDepths.v1"].(object); ok {
		for format, key := range map[string]string{"png": "pngDepth", "tiff": "tiffDepth"} {
			if value, ok := depths[format]; ok {
				if err := export.update(key, value); err == nil {
					e[key] = value
				}
			}
		}
	}
	// Swift 舊遷移尚未執行時，有效 PNG 預設就是 8 bit。
	if v["photoExportPNG8Default.v1"] != true {
		e["pngDepth"] = 8
	}
	if len(e) > 0 {
		p["exportSettings"] = e
	}
	if err := a.mergeLegacyState("preferences.json", p); err != nil {
		return err
	}
	if err := a.loadPreferences(); err != nil {
		return err
	}
	if raw, ok := v["stylePrompts.v1"]; ok {
		data, _ := json.Marshal(raw)
		var prompts map[string]map[string]string
		if json.Unmarshal(data, &prompts) != nil {
			var flat map[string]string
			if err := json.Unmarshal(data, &flat); err != nil {
				a.migrationProblem("stylePrompts.v1", err, "")
			} else {
				prompts = map[string]map[string]string{}
				for id, text := range flat {
					prompts[id] = map[string]string{"english": text}
				}
			}
		}
		incoming := object{}
		for id, langs := range prompts {
			if _, ok := a.defaults[id]; !ok {
				a.migrationProblem("stylePrompts.v1/"+id, errors.New("底片不存在"), "")
				continue
			}
			next := object{}
			for lang, text := range langs {
				if promptLanguage(lang) == lang && len(text) <= 32768 {
					next[lang] = text
				}
			}
			incoming[id] = next
		}
		if err := a.mergeLegacyState("prompts.json", incoming); err != nil {
			return err
		}
		if _, err := a.store.LoadState("prompts.json", &a.prompts); err != nil {
			return err
		}
	}
	b := object{"version": 1}
	photo, _ := v["lastImageImportFilePath.v1"].(string)
	directory, _ := v["lastPhotoDirectoryPath.v1"].(string)
	if directory == "" && photo != "" {
		directory = filepath.Dir(photo)
	}
	if directory != "" {
		b["directory"] = directory
	}
	if photo != "" {
		b["photo"] = photo
	}
	if entries, ok := v["recentPhotoDirectories.v1"].([]any); ok {
		recent := []string{}
		for _, entry := range entries {
			if m, ok := entry.(object); ok {
				if path, ok := m["path"].(string); ok && path != "" {
					recent = append(recent, path)
				}
			}
		}
		b["recent"] = recent
	}
	if err := a.mergeLegacyState("browser.json", b); err != nil {
		return err
	}
	m := object{"version": 1}
	for old, next := range map[string]string{"photoStyle.ai.modelDirectory.path": "directory", "photoStyle.ai.modelDirectory.selectedModel": "selected", "photoStyle.ai.enabled": "enabled"} {
		if value, ok := v[old]; ok {
			m[next] = value
		}
	}
	if err := a.mergeLegacyState("models.json", m); err != nil {
		return err
	}
	if ui, ok := v["webPreferences"].(object); ok {
		if err := a.mergeLegacyState("ui-preferences.json", allowedUIPreferences(ui)); err != nil {
			return err
		}
	}
	if err := a.migrateDecorations(v["styleAdjustments.v1"]); err != nil {
		return err
	}
	if err := a.migratePrivateSource(); err != nil {
		a.migrationProblem("最後照片快取", err, "")
	}
	return a.migrateMCPConnection()
}

func (a *App) migrateMCPConnection() error {
	if a.legacyPhotoDirectory == "" {
		return nil
	}
	dest := filepath.Join(a.store.Root(), "MCP", "connection.json")
	if _, err := os.Stat(dest); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	source := filepath.Join(filepath.Dir(a.legacyPhotoDirectory), "MCP", "connection.json")
	data, err := readBounded(source, 64*1024)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var config struct {
		Servers map[string]struct {
			URL     string            `json:"url"`
			Headers map[string]string `json:"headers"`
		} `json:"mcpServers"`
	}
	if json.Unmarshal(data, &config) != nil {
		return errors.New("舊 MCP 設定格式錯誤，請重新複製連線設定")
	}
	server := config.Servers["FilmYourPhoto"]
	token := strings.TrimPrefix(server.Headers["Authorization"], "Bearer ")
	if server.URL != "http://127.0.0.1:8765/mcp" || len(token) < 32 || len(token) > 256 || strings.ContainsAny(token, "\r\n\t ") {
		return errors.New("舊 MCP 設定無法安全沿用，請重新複製連線設定")
	}
	if err = os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
		return err
	}
	// 只帶本機端點與認證，不匯入其他任意設定。權杖不寫入移轉報告。
	data, _ = json.Marshal(object{"mcpServers": object{"FilmYourPhoto": object{"url": server.URL, "headers": object{"Authorization": "Bearer " + token}}}})
	f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	closeErr := f.Close()
	return errors.Join(err, closeErr)
}

func (a *App) migrationSummary() string {
	a.migrationMu.Lock()
	defer a.migrationMu.Unlock()
	var text strings.Builder
	fmt.Fprintln(&text, "新版已保存的值優先；已移轉項目刪除後不再回灌。移轉前的設定備份保存在 recovery。")
	for _, issue := range a.migrationIssues {
		fmt.Fprintf(&text, "\n%s：%s", issue.Source, issue.Message)
		if issue.Recovery != "" {
			fmt.Fprintf(&text, "\n保留原檔：%s", issue.Recovery)
		}
	}
	var ledger migrationLedger
	if found, err := a.store.LoadState("migrations.json", &ledger); found && err == nil {
		imported, kept := 0, 0
		for _, receipt := range ledger.Items {
			if receipt.Disposition == "已匯入" {
				imported++
			} else {
				kept++
			}
		}
		fmt.Fprintf(&text, "\n移轉收據：已匯入 %d 項、保留新版 %d 項。", imported, kept)
	}
	var assets object
	if found, err := a.store.LoadState("legacy-assets.json", &assets); found && err == nil {
		fmt.Fprintf(&text, "\n已保存舊照片資產 %d 份。", len(assets))
	}
	text.WriteString("\n離線原圖可透過「匯入並重新定位」重新對應；完整舊檔保存在 legacy，匯入資料包保存在 imports。")
	if len(a.migrationIssues) == 0 {
		text.WriteString("\n目前沒有已記錄的移轉問題。")
	}
	return text.String()
}
