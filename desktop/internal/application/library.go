package application

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"unicode"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/rivo/uniseg"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

//go:embed prompts.json
var promptData []byte
var defaultPrompts struct {
	System  string
	Grammar string
	Styles  map[string]struct {
		Prompts  map[string]string
		Guidance string
		Strength []int
	}
	CropAspectRatios []object
}

func init() {
	if err := json.Unmarshal(promptData, &defaultPrompts); err != nil {
		panic(err)
	}
}

type CustomFilm struct {
	ID         string          `json:"id"`
	Name       string          `json:"name"`
	BaseStyle  string          `json:"baseStyle"`
	Adjustment json.RawMessage `json:"adjustment"`
}

func filmRecipe(f CustomFilm) contract.Recipe {
	return contract.Recipe{Version: 1, Style: f.BaseStyle, Adjustment: f.Adjustment, RepairPatches: json.RawMessage(`[]`)}
}
func (a *App) loadUserLibrary() error {
	a.prompts = map[string]map[string]string{}
	var existing []json.RawMessage
	found, err := a.store.LoadState("custom-films.json", &existing)
	if err != nil {
		a.recoverState("custom-films.json", err)
		found = false
	}
	explicitEmpty := found && len(existing) == 0
	next := []CustomFilm{}
	seen := map[string]bool{}
	damaged := false
	decode := func(raw json.RawMessage, source string) (CustomFilm, bool) {
		var film CustomFilm
		err := json.Unmarshal(raw, &film)
		if err == nil && (!strings.HasPrefix(film.ID, "custom-") || seen[film.ID]) {
			err = errors.New("自訂底片識別重複或格式錯誤")
		}
		if err == nil {
			film.Name, err = validName(film.Name, 80)
		}
		if err == nil {
			var r contract.Recipe
			r, err = a.services.NormalizeRecipe(filmRecipe(film))
			film.Adjustment = r.Adjustment
		}
		if err != nil {
			a.migrationProblem(source, err, "")
			return film, false
		}
		seen[film.ID] = true
		return film, true
	}
	for i, raw := range existing {
		if f, ok := decode(raw, fmt.Sprintf("custom-films.json/%d", i)); ok {
			next = append(next, f)
		} else {
			damaged = true
		}
	}
	a.customFilms = next
	a.catalog["cropAspectRatios"] = defaultPrompts.CropAspectRatios
	if _, e := a.store.LoadState("prompts.json", &a.prompts); e != nil {
		a.recoverState("prompts.json", e)
		a.prompts = map[string]map[string]string{}
	}
	ledger := migrationLedger{Version: 1, Items: map[string]migrationReceipt{}}
	if _, err := a.store.LoadState("migrations.json", &ledger); err != nil {
		return err
	}
	if ledger.Version != 1 || ledger.Items == nil {
		return errors.New("移轉紀錄版本不符")
	}
	preserveEmpty := explicitEmpty
	for key := range ledger.Items {
		if strings.HasPrefix(key, "custom-films.json:") {
			preserveEmpty = false
			break
		}
	}
	changed := damaged
	if a.legacyPhotoDirectory != "" {
		path := filepath.Join(filepath.Dir(a.legacyPhotoDirectory), "CustomFilms.json")
		data, err := readBounded(path, 16*1024*1024)
		if err == nil {
			var records []json.RawMessage
			if err = json.Unmarshal(data, &records); err != nil {
				a.migrationProblem(path, err, path)
			} else {
				for i, raw := range records {
					var identity struct {
						ID string `json:"id"`
					}
					_ = json.Unmarshal(raw, &identity)
					receipt := "custom-films.json:" + identity.ID
					if _, done := ledger.Items[receipt]; done {
						continue
					}
					if seen[identity.ID] || preserveEmpty {
						ledger.Items[receipt] = migrationReceipt{sourceHash(raw), "保留新版"}
						changed = true
						continue
					}
					if f, ok := decode(raw, fmt.Sprintf("%s/%d", path, i)); ok {
						next = append(next, f)
						ledger.Items[receipt] = migrationReceipt{sourceHash(raw), "已匯入"}
						changed = true
					}
				}
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			a.migrationProblem(path, err, path)
		}
	}
	if changed {
		if err := a.store.CommitStates(map[string]any{"custom-films.json": next, "migrations.json": ledger}); err != nil {
			return err
		}
	}
	a.customFilms = next
	if _, err := a.store.LoadState("prompts.json", &a.prompts); err != nil {
		a.recoverState("prompts.json", err)
		a.prompts = map[string]map[string]string{}
	}
	a.catalog["cropAspectRatios"] = defaultPrompts.CropAspectRatios
	return nil
}
func promptLanguage(value string) string {
	switch value {
	case "english", "en":
		return "english"
	case "japanese", "ja":
		return "japanese"
	case "korean", "ko":
		return "korean"
	default:
		return "traditionalChinese"
	}
}

func (a *App) effectivePromptLanguage() string {
	value := a.preferences.PromptLanguage
	if value == "" {
		value = a.preferences.Language
	}
	if value == "automatic" || value == "" {
		return promptLanguage(a.systemLanguage)
	}
	return promptLanguage(value)
}
func (a *App) stylePayloads() []any {
	entries := snapshotJSON(a.catalog["styles"]).([]any)
	language := a.effectivePromptLanguage()
	for _, raw := range entries {
		s := raw.(object)
		id := s["id"].(string)
		defaults := defaultPrompts.Styles[id].Prompts
		prompts := maps.Clone(defaults)
		customized := []string{}
		for lang, p := range a.prompts[id] {
			if p != "" && p != defaults[lang] {
				prompts[lang] = p
				customized = append(customized, lang)
			}
		}
		s["prompts"] = prompts
		s["defaultPrompts"] = defaults
		s["prompt"] = prompts[language]
		s["defaultPrompt"] = defaults[language]
		s["promptCustomized"] = prompts[language] != defaults[language]
		s["promptCustomizedLanguages"] = customized
	}
	for _, f := range a.customFilms {
		for _, raw := range entries {
			base := raw.(object)
			if base["id"] == f.BaseStyle {
				s := snapshotJSON(base).(object)
				s["id"] = f.ID
				s["title"] = f.Name
				s["subtitle"] = "以「" + base["title"].(string) + "」為基礎儲存的自訂參數。"
				s["isCustom"] = true
				s["isHiddenFromCatalog"] = false
				s["baseStyle"] = f.BaseStyle
				s["mergedInto"] = ""
				s["filmFamilyTitle"] = "自訂底片"
				entries = append(entries, s)
				break
			}
		}
	}
	return entries
}
func (a *App) findFilm(id string) (CustomFilm, bool) {
	for _, f := range a.customFilms {
		if f.ID == id {
			return f, true
		}
	}
	return CustomFilm{}, false
}

func (a *App) currentDefaults() object {
	if film, ok := a.findFilm(a.selectedCustom); ok {
		r, err := a.services.NormalizeRecipe(filmRecipe(film))
		if err == nil {
			if values, err := a.services.ProjectRecipes(map[string]contract.Recipe{r.Style: r}); err == nil {
				return values[r.Style]
			}
		}
	}
	return a.defaultUI[a.selected]
}
func (a *App) recipeForLook(id string) (contract.Recipe, bool) {
	if f, ok := a.findFilm(id); ok {
		r, err := a.services.NormalizeRecipe(filmRecipe(f))
		return r, err == nil
	}
	r, ok := a.recipes[id]
	if !ok {
		return contract.Recipe{}, false
	}
	if a.selectedCustom != "" && a.customBase != nil && id == a.customBase.Style {
		r = *a.customBase
	}
	r = clone(r)
	if _, ready := a.activeModel(); !ready || a.modelBusy || id == "original" {
		next, previous := recipeFields(a.defaults[id]), recipeFields(r)
		for _, key := range []string{"frameEnabled", "frameStyle", "dateEnabled", "dateStyle", "colorCalibration"} {
			if value, exists := previous[key]; exists && (key != "colorCalibration" || id != "original") {
				next[key] = value
			}
		}
		r = withFields(a.defaults[id], next)
	} else {
		next, current := recipeFields(r), recipeFields(a.recipes[a.selected])
		if next["sourceToneZones"] == nil {
			next["exposure"] = current["exposure"]
		}
		next["hdrAmount"] = current["hdrAmount"]
		if next["hdrToneCurve"] == nil && current["hdrToneCurve"] != nil {
			next["hdrToneCurve"] = current["hdrToneCurve"]
		}
		r = withFields(r, next)
	}
	return r, true
}
func (a *App) selectStyle(id string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	next, ok := a.recipeForLook(id)
	if !ok {
		return errors.New("找不到指定底片")
	}
	if a.selectedCustom == "" && id == a.selected && id != "original" {
		if _, ready := a.activeModel(); ready && !a.modelBusy {
			return nil
		}
	}
	a.pushHistory()
	current := clone(a.recipes[a.selected])
	if a.customBase != nil {
		a.recipes[a.customBase.Style] = clone(*a.customBase)
	}
	a.selectedCustom = ""
	a.customBase = nil
	if _, ok := a.findFilm(id); ok {
		base := clone(a.recipes[next.Style])
		a.customBase = &base
		a.selectedCustom = id
	}
	a.selected = next.Style
	a.recipes[a.selected] = preserveGeometry(next, current)
	return a.refreshUI()
}
func filmNameKey(value string) string {
	value = cases.Fold().String(norm.NFD.String(value))
	return strings.Map(func(r rune) rune {
		if unicode.Is(unicode.Mn, r) {
			return -1
		}
		return r
	}, value)
}
func validName(name string, max int) (string, error) {
	name = norm.NFC.String(strings.TrimSpace(name))
	if name == "" || uniseg.GraphemeClusterCount(name) > max || strings.IndexFunc(name, func(r rune) bool { return unicode.IsControl(r) || unicode.Is(unicode.Cf, r) }) >= 0 {
		return "", fmt.Errorf("名稱需要 1～%d 個字，且不可含控制字元", max)
	}
	return name, nil
}
func (a *App) saveFilm(name string, recipe contract.Recipe, sourceID string) error {
	name, err := validName(name, 80)
	if err != nil {
		return err
	}
	var updatedUI object
	a.mu.Lock()
	defer func() {
		a.mu.Unlock()
		if updatedUI != nil {
			a.reply("handleUIPreferences", updatedUI)
		}
	}()
	id := ""
	if original, ok := a.findFilm(sourceID); ok && original.Name == name {
		id = sourceID
	}
	for _, f := range a.customFilms {
		if f.ID != id && filmNameKey(f.Name) == filmNameKey(name) {
			return errors.New("已有同名自訂底片")
		}
	}
	if id == "" {
		u := identifier()
		id = "custom-" + u[:8] + "-" + u[8:12] + "-" + u[12:16] + "-" + u[16:20] + "-" + u[20:]
	}
	fields := recipeFields(recipe)
	for k := range fields {
		if strings.HasPrefix(k, "crop") {
			delete(fields, k)
		}
	}
	data, _ := json.Marshal(fields)
	f := CustomFilm{ID: id, Name: name, BaseStyle: recipe.Style, Adjustment: data}
	next := clone(a.customFilms)
	replaced := false
	for i, v := range next {
		if v.ID == id {
			next[i] = f
			replaced = true
		}
	}
	if !replaced {
		next = append(next, f)
	}
	ui := object{}
	if _, err = a.store.LoadState("ui-preferences.json", &ui); err != nil {
		return err
	}
	const enabledKey = "photoStyle.enabledFilms.v2"
	if raw, exists := ui[enabledKey]; exists {
		var enabled []string
		value, valid := raw.(string)
		if !valid || json.Unmarshal([]byte(value), &enabled) != nil {
			return errors.New("底片勾選設定格式不符")
		}
		if !contains(enabled, id) {
			enabled = append(enabled, id)
		}
		encoded, _ := json.Marshal(enabled)
		ui[enabledKey] = string(encoded)
		// 底片與勾選一起保存，避免只完成其中一份；沒有清單時前端預設全選。
		err = a.store.CommitStates(map[string]any{"custom-films.json": next, "ui-preferences.json": ui})
	} else {
		err = a.store.SaveState("custom-films.json", next)
	}
	if err != nil {
		return err
	}
	a.customFilms = next
	if _, exists := ui[enabledKey]; exists {
		updatedUI = ui
	}
	return nil
}
func (a *App) handleLibrary(action string, m object) error {
	if action == "updateStylePrompt" || action == "resetStylePrompt" {
		id, _ := m["style"].(string)
		lang := promptLanguage(stringValue(m, "language"))
		prompt := strings.TrimSpace(stringValue(m, "prompt"))
		if len(prompt) > 32768 {
			return errors.New("提示詞過長")
		}
		a.mu.Lock()
		if _, ok := a.defaults[id]; !ok {
			a.mu.Unlock()
			return errors.New("底片不存在")
		}
		next := clone(a.prompts)
		if next[id] == nil {
			next[id] = map[string]string{}
		}
		if action == "resetStylePrompt" || prompt == defaultPrompts.Styles[id].Prompts[lang] {
			delete(next[id], lang)
		} else {
			next[id][lang] = prompt
		}
		err := a.store.SaveState("prompts.json", next)
		if err == nil {
			a.prompts = next
		}
		a.mu.Unlock()
		if err == nil {
			a.state()
		}
		return err
	}
	a.mu.Lock()
	recipe := clone(a.recipes[a.selected])
	sourceID := a.selectedCustom
	id, _ := m["id"].(string)
	if id == "" {
		id = sourceID
	}
	film, exists := a.findFilm(id)
	generation := a.generation
	a.mu.Unlock()
	switch action {
	case "saveCustomFilm":
		value := ""
		if exists {
			value = film.Name
		}
		return a.showDialog("儲存自訂底片", "保留沖洗參數；照片的裁切與修復不會存入底片。", value, nil, func(name string) error {
			a.mu.Lock()
			valid := a.generation == generation && a.selectedCustom == sourceID && reflect.DeepEqual(a.recipes[a.selected], recipe)
			a.mu.Unlock()
			if !valid {
				return errors.New("照片調整已變更，請重新儲存底片")
			}
			if err := a.saveFilm(name, recipe, sourceID); err != nil {
				return err
			}
			a.mu.Lock()
			a.pushHistory()
			if a.selectedCustom == "" {
				base := clone(recipe)
				a.customBase = &base
			}
			a.selectedCustom = a.filmIDByName(name)
			a.mu.Unlock()
			if err := a.persist(); err != nil {
				return err
			}
			a.state()
			return nil
		})
	case "importCustomFilm":
		path, err := wruntime.OpenFileDialog(a.ctx, wruntime.OpenDialogOptions{Title: "匯入自訂底片", Filters: []wruntime.FileFilter{{DisplayName: "底片 JSON", Pattern: "*.json"}}})
		if err != nil || path == "" {
			return err
		}
		data, err := readBounded(path, 1048576)
		if err != nil {
			return err
		}
		var transfer struct {
			CustomFilm
			Format  string `json:"format"`
			Version int    `json:"version"`
		}
		if err = json.Unmarshal(data, &transfer); err != nil {
			return err
		}
		if transfer.Format != "FilmDevelop.custom-film" || transfer.Version != 1 || !strings.HasPrefix(transfer.ID, "custom-") {
			return errors.New("底片格式或版本不符")
		}
		r, err := a.services.NormalizeRecipe(filmRecipe(transfer.CustomFilm))
		if err != nil {
			return err
		}
		// 匯入沿用原 ID；名稱衝突以副本名稱保存，不覆寫另一款底片。
		a.mu.Lock()
		next := clone(a.customFilms)
		f := transfer.CustomFilm
		f.Adjustment = r.Adjustment
		if _, err = validName(f.Name, 80); err == nil {
			for n := 2; ; n++ {
				collision := false
				for _, v := range next {
					if v.ID != f.ID && filmNameKey(v.Name) == filmNameKey(f.Name) {
						collision = true
					}
				}
				if !collision {
					break
				}
				f.Name = fmt.Sprintf("%.60s (%d)", transfer.Name, n)
			}
			replaced := false
			for i, v := range next {
				if v.ID == f.ID {
					next[i] = f
					replaced = true
				}
			}
			if !replaced {
				next = append(next, f)
			}
			err = a.store.SaveState("custom-films.json", next)
			if err == nil {
				a.customFilms = next
			}
		}
		a.mu.Unlock()
		if err != nil {
			return err
		}
		a.state()
		return nil
	case "exportCustomFilm":
		if !exists {
			return errors.New("請先選取自訂底片")
		}
		data, err := json.MarshalIndent(struct {
			CustomFilm
			Format  string `json:"format"`
			Version int    `json:"version"`
		}{film, "FilmDevelop.custom-film", 1}, "", "  ")
		if err != nil {
			return err
		}
		name := strings.Map(func(r rune) rune {
			if strings.ContainsRune(`/\:*?"<>|`, r) {
				return '_'
			}
			return r
		}, film.Name)
		path, err := wruntime.SaveFileDialog(a.ctx, wruntime.SaveDialogOptions{Title: "匯出自訂底片", DefaultFilename: name + ".json"})
		if err != nil || path == "" {
			return err
		}
		return writeConfirmedFile(path, data)
	case "deleteCustomFilm":
		if !exists {
			return errors.New("自訂底片不存在")
		}
		return a.showDialog("刪除自訂底片", "刪除「"+film.Name+"」？目前照片的調整會保留。", "", []dialogChoice{{ID: "delete", Label: "刪除", Role: "destructive"}}, func(string) error {
			a.mu.Lock()
			next := []CustomFilm{}
			for _, f := range a.customFilms {
				if f.ID != id {
					next = append(next, f)
				}
			}
			err := a.store.SaveState("custom-films.json", next)
			if err == nil {
				a.customFilms = next
				if a.selectedCustom == id {
					a.selectedCustom = ""
					a.customBase = nil
				}
				for _, history := range [][]editSnapshot{a.undo, a.redo} {
					for i := range history {
						if history[i].CustomID == id {
							history[i].CustomID, history[i].CustomBase = "", nil
						}
					}
				}
			}
			a.mu.Unlock()
			if err != nil {
				return err
			}
			if err = a.persist(); err != nil {
				return err
			}
			a.state()
			return nil
		})
	case "showCustomFilmMenu":
		if !exists {
			return errors.New("自訂底片不存在")
		}
		return a.showMenu(film.Name, []contextMenuItem{{ID: "rename", Label: "重新命名"}, {ID: "duplicate", Label: "複製底片"}, menuSeparator(), {ID: "export", Label: "匯出底片"}, menuSeparator(), {ID: "delete", Label: "刪除底片"}}, m, func(command string) error {
			switch command {
			case "delete":
				return a.handleLibrary("deleteCustomFilm", object{"id": id})
			case "export":
				return a.handleLibrary("exportCustomFilm", object{"id": id})
			case "duplicate":
				return a.duplicateFilm(film)
			default:
				return a.showDialog("重新命名底片", "", film.Name, nil, func(name string) error {
					name, err := validName(name, 80)
					if err != nil {
						return err
					}
					a.mu.Lock()
					next := clone(a.customFilms)
					for _, f := range next {
						if f.ID != id && filmNameKey(f.Name) == filmNameKey(name) {
							a.mu.Unlock()
							return errors.New("已有同名自訂底片")
						}
					}
					for i, f := range next {
						if f.ID == id {
							next[i].Name = name
						}
					}
					err = a.store.SaveState("custom-films.json", next)
					if err == nil {
						a.customFilms = next
					}
					a.mu.Unlock()
					if err == nil {
						a.state()
					}
					return err
				})
			}
		})
	}
	return errors.New("未知底片操作")
}
func stringValue(m object, key string) string { v, _ := m[key].(string); return v }
func writeExclusive(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		_ = os.Remove(path)
		return err
	}
	return closeErr
}
