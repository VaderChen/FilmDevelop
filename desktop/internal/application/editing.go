package application

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type editSnapshot struct {
	SubjectMask *storage.SubjectMask
	Manual      storage.ManualAdjustments
	Selected    string
	Recipes     map[string]contract.Recipe
	CustomID    string
	CustomBase  *contract.Recipe
}

// 每次復原還原整個編輯交易，包含底片選取、共用幾何與修復資料。
func (a *App) snapshot() editSnapshot {
	return editSnapshot{SubjectMask: clone(a.subjectMask), Manual: clone(a.manual), Selected: a.selected, Recipes: copyRecipes(a.recipes), CustomID: a.selectedCustom, CustomBase: clone(a.customBase)}
}
func (a *App) restore(s editSnapshot) error {
	a.subjectMask = clone(s.SubjectMask)
	a.manual = clone(s.Manual)
	a.selected = s.Selected
	a.recipes = copyRecipes(s.Recipes)
	a.selectedCustom = s.CustomID
	a.customBase = clone(s.CustomBase)
	return a.refreshUI()
}

// 配方 JSON 只以完整新值取代，歷史記錄可共用不可變的補片位元組。
func copyRecipes(source map[string]contract.Recipe) map[string]contract.Recipe {
	result := make(map[string]contract.Recipe, len(source))
	for id, recipe := range source {
		result[id] = recipe
	}
	return result
}
func (a *App) pushHistory() {
	a.undo = append(a.undo, a.snapshot())
	if len(a.undo) > 100 {
		a.undo = a.undo[len(a.undo)-100:]
	}
	a.redo = nil
}
func recipeFields(r contract.Recipe) object {
	var p object
	_ = json.Unmarshal(r.Adjustment, &p)
	return p
}
func withFields(r contract.Recipe, fields object) contract.Recipe {
	r.Adjustment, _ = json.Marshal(fields)
	return r
}
func preserveGeometry(next, current contract.Recipe) contract.Recipe {
	n, c := recipeFields(next), recipeFields(current)
	for _, k := range []string{"cropAspectRatio", "cropRotation", "cropScale", "cropWidth", "cropHeight", "cropHorizontalPosition", "cropVerticalPosition"} {
		if v, ok := c[k]; ok {
			n[k] = v
		}
	}
	n["imageScoped"] = true
	next.RepairPatches = clone(current.RepairPatches)
	return withFields(next, n)
}
func (a *App) sampleWhiteBalance(message object) error {
	a.mu.Lock()
	if a.source == "" || a.previewBusy() || message["photoGeneration"] != a.generation || message["style"] != a.selected || message["previewRevision"] != float64(a.revision) {
		a.mu.Unlock()
		return nil
	}
	custom, _ := message["customFilmID"].(string)
	if custom != a.selectedCustom {
		a.mu.Unlock()
		return nil
	}
	recipe := clone(a.recipes[a.selected])
	ui := clone(a.ui[a.selected])
	generation, revision := a.generation, a.revision
	for _, s := range a.catalog["styles"].([]any) {
		v := s.(object)
		if v["id"] == a.selected && v["isMonochrome"] == true {
			a.mu.Unlock()
			return errors.New("請使用彩色照片取樣白平衡。")
		}
	}
	a.mu.Unlock()
	var rgb []float64
	data, _ := json.Marshal(message["rgb"])
	if json.Unmarshal(data, &rgb) != nil || len(rgb) != 3 {
		return errors.New("白平衡取樣格式不符")
	}
	for _, v := range rgb {
		if v < 0 || v > 1 {
			return errors.New("白平衡取樣超出範圍")
		}
	}
	strength, _ := ui["intensity"].(float64)
	if strength <= 0 {
		return errors.New("請先提高風格強度，再取樣白平衡。")
	}
	warmth, _ := ui["whiteBalanceWarmth"].(float64)
	tint, _ := ui["whiteBalanceTint"].(float64)
	data, err := a.services.Native(a.ctx, "whiteBalance", contract.WhiteBalanceRequest{Red: rgb[0], Green: rgb[1], Blue: rgb[2], Warmth: warmth, Tint: tint, Strength: strength / 100}, nil)
	if err != nil {
		return err
	}
	var result struct{ Warmth, Tint float64 }
	if err = json.Unmarshal(data, &result); err != nil {
		return err
	}
	a.mu.Lock()
	current := a.generation == generation && a.revision == revision && reflect.DeepEqual(recipe, a.recipes[a.selected])
	a.mu.Unlock()
	if !current {
		return nil
	}
	if err = a.update(object{"adjustments": []any{object{"key": "whiteBalanceWarmth", "value": result.Warmth}, object{"key": "whiteBalanceTint", "value": result.Tint}}, "photoGeneration": generation}); err != nil {
		return err
	}
	if err = a.persist(); err != nil {
		return err
	}
	a.preview()
	return nil
}
func (a *App) colorCalibration(clear bool) error {
	var calibration any
	if !clear {
		path, err := wruntime.OpenFileDialog(a.ctx, wruntime.OpenDialogOptions{Title: "匯入線性色彩校準 JSON", Filters: []wruntime.FileFilter{{DisplayName: "JSON", Pattern: "*.json"}}})
		if err != nil || path == "" {
			return err
		}
		data, err := readBounded(path, 65536)
		if err != nil {
			return err
		}
		if err = json.Unmarshal(data, &calibration); err != nil {
			return err
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.source == "" {
		return errors.New("請先選取照片")
	}
	recipe := a.recipes[a.selected]
	fields := recipeFields(recipe)
	if clear {
		delete(fields, "colorCalibration")
	} else {
		fields["colorCalibration"] = calibration
	}
	fields["imageScoped"] = true
	next, err := a.services.NormalizeRecipe(withFields(recipe, fields))
	if err != nil {
		return err
	}
	a.pushHistory()
	a.recipes[a.selected] = next
	return a.refreshUI()
}
func readBounded(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("檔案格式或大小不符")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("檔案超過大小限制")
	}
	return data, nil
}
func (a *App) cancelHover(id string) {
	a.mu.Lock()
	if id != "" && id != a.hoverID {
		a.mu.Unlock()
		return
	}
	if a.hoverCancel != nil {
		a.hoverCancel()
		a.hoverCancel = nil
	}
	a.hoverID = ""
	a.mu.Unlock()
}
func (a *App) filmHover(message object) error {
	a.cancelHover("")
	a.mu.Lock()
	id, _ := message["requestID"].(string)
	style, _ := message["style"].(string)
	if a.source == "" || a.previewBusy() || a.saving || id == "" || len(id) > 80 || message["photoGeneration"] != a.generation || message["previewRevision"] != float64(a.revision) {
		a.mu.Unlock()
		return nil
	}
	recipe, ok := a.recipeForLook(style)
	if !ok {
		a.mu.Unlock()
		return errors.New("底片不存在")
	}
	recipe = preserveGeometry(recipe, a.recipes[a.selected])
	recipe.DetectSubject = false
	job := a.job("", recipe, true)
	generation, revision := a.generation, a.revision
	ctx, cancel := context.WithCancel(a.ctx)
	a.hoverCancel = cancel
	a.hoverID = id
	a.mu.Unlock()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		dir, err := os.MkdirTemp("", "filmdevelop-hover-")
		if err != nil {
			return
		}
		defer os.RemoveAll(dir)
		job.Output.Path = filepath.Join(dir, "hover.png")
		result, err := a.services.Render(ctx, job, nil)
		if err != nil {
			return
		}
		image, err := previewData(job.Output.Path)
		if err != nil {
			return
		}
		var size object
		_ = json.Unmarshal(result, &size)
		a.mu.Lock()
		valid := ctx.Err() == nil && a.hoverID == id && a.generation == generation && a.revision == revision
		a.mu.Unlock()
		if valid {
			a.reply("handleFilmHoverPreview", object{"requestID": id, "style": style, "photoGeneration": generation, "previewRevision": revision, "image": image, "width": size["width"], "height": size["height"]})
		}
	}()
	return nil
}
func (a *App) reply(function string, payload any) {
	if a.emit != nil {
		a.emit(function, payload)
		return
	}
	wruntime.EventsEmit(a.ctx, "filmdevelop:reply", object{"function": function, "payload": payload})
}
