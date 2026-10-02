package application

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	"github.com/VaderChen/FilmDevelop/internal/transfer"
)

const repairModelRevision = "5ed76e3799ab4cad31381750d29880c267477e18"

func (a *App) repairRevision() string {
	var patches []object
	_ = json.Unmarshal(a.recipes[a.selected].RepairPatches, &patches)
	ids := []string{}
	for _, p := range patches {
		ids = append(ids, stringValue(p, "id"))
	}
	return strings.Join(ids, ":")
}
func (a *App) prepareRepairModel(ctx context.Context) (string, error) {
	root, err := storage.DataDirectory()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "windows" {
		const revision = "c3c0c9e468934d62e79c329e35d82dd09ff8c444"
		directory := filepath.Join(root, "repair-models", "LaMa-ONNX-"+revision)
		files := []transfer.File{{Path: "lama_fp32.onnx", Size: 208044816,
			SHA256: "1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6",
			URL:    "https://huggingface.co/Carve/LaMa-ONNX/resolve/" + revision + "/lama_fp32.onnx"}}
		err = transfer.EnsureManagedDirectory(ctx, directory, files, func(p transfer.Progress) {
			a.mu.Lock()
			a.repairProgress = object{"received": p.Received, "total": p.Total, "preparing": false}
			a.repairStep = "首次使用：正在下載修復模型"
			a.mu.Unlock()
			a.state()
		})
		return directory, err
	}
	directory := filepath.Join(root, "repair-models", "LaMa-"+repairModelRevision)
	if runtime.GOOS == "darwin" {
		home, e := os.UserConfigDir()
		if e == nil {
			legacy := filepath.Join(home, "PhotoStyleApp", "RepairModels", "LaMa-"+repairModelRevision)
			if _, e = os.Stat(filepath.Join(legacy, "LaMa.mlmodelc", "coremldata.bin")); e == nil {
				return legacy, nil
			}
		}
	}
	if _, e := os.Stat(filepath.Join(directory, "LaMa.mlmodelc", "coremldata.bin")); e == nil {
		return directory, nil
	}
	packagePath := filepath.Join(directory, "LaMa.mlpackage")
	if _, e := os.Stat(packagePath); errors.Is(e, os.ErrNotExist) {
		files := []transfer.File{
			{Path: "Manifest.json", Size: 617, SHA256: "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58"},
			{Path: "Data/com.apple.CoreML/model.mlmodel", Size: 1101809, SHA256: "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953"},
			{Path: "Data/com.apple.CoreML/weights/weight.bin", Size: 215544960, SHA256: "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184"},
		}
		for i := range files {
			files[i].URL = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/" + repairModelRevision + "/LaMa.mlpackage/" + files[i].Path
		}
		err = transfer.InstallDirectory(ctx, packagePath, files, nil, func(p transfer.Progress) {
			a.mu.Lock()
			a.repairProgress = object{"received": p.Received, "total": p.Total, "preparing": false}
			a.repairStep = "首次使用：正在下載修復模型"
			a.mu.Unlock()
			a.state()
		})
		if err != nil {
			return "", err
		}
	} else if e != nil {
		return "", e
	}
	return directory, nil
}
func (a *App) repairBrush(action string, message object) error {
	a.mu.Lock()
	if action == "cancelRepairBrush" {
		if a.repairing && a.cancel != nil {
			a.cancel()
		}
		a.mu.Unlock()
		return nil
	}
	callback := "handleRepairPreparation"
	apply := action == "applyRepairBrush"
	if apply {
		callback = "handleRepairResult"
	}
	generation := a.generation
	if a.source == "" || a.previewBusy() || a.saving || a.computing || a.repairing || message["photoGeneration"] != generation || (apply && message["repairRevision"] != a.repairRevision()) {
		a.mu.Unlock()
		a.reply(callback, object{"success": false, "photoGeneration": message["photoGeneration"]})
		return nil
	}
	recipe := clone(a.recipes[a.selected])
	input := a.job("", recipe, true).Input
	revision := a.revision
	strokes, err := json.Marshal(message["strokes"])
	if apply && (err != nil || len(strokes) > 2*1024*1024) {
		a.mu.Unlock()
		return errors.New("修復筆刷資料無效或過大")
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	a.repairing = true
	a.repairStep = "正在準備本機修復工具"
	a.repairProgress = object{"preparing": true, "received": 0, "total": 0}
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		directory, err := a.prepareRepairModel(ctx)
		var result json.RawMessage
		if err == nil {
			if apply {
				a.mu.Lock()
				a.repairStep = "正在修復塗抹區域"
				a.repairProgress = nil
				a.mu.Unlock()
				a.state()
				result, err = a.services.Native(ctx, "repair", contract.RepairRequest{Input: input, Recipe: recipe, ModelDirectory: directory, Strokes: strokes}, nil)
			} else {
				_, err = a.services.Native(ctx, "prepareRepair", contract.FileRequest{Path: directory}, nil)
			}
		}
		a.mu.Lock()
		valid := err == nil && ctx.Err() == nil && a.generation == generation && a.revision == revision
		if valid && apply {
			var patch object
			err = json.Unmarshal(result, &patch)
			if err == nil && stringValue(patch, "id") == "" {
				err = errors.New("修復引擎回覆不完整")
			}
			if err == nil {
				var patches []json.RawMessage
				_ = json.Unmarshal(recipe.RepairPatches, &patches)
				patches = append(patches, result)
				data, _ := json.Marshal(patches)
				if len(data)+len(recipe.Adjustment) > contract.MaxMessageBytes*3/4 {
					err = errors.New("修復紀錄過大，請先匯出成品再繼續")
				} else {
					a.pushHistory()
					for id, r := range a.recipes {
						r.RepairPatches = data
						a.recipes[id] = r
					}
					a.skipSubject = false
					a.revision++
				}
			}
		}
		a.repairing = false
		a.repairStep = ""
		a.repairProgress = nil
		a.mu.Unlock()
		if err != nil && ctx.Err() == nil {
			a.toast(err)
		}
		if valid && err == nil && apply {
			if err = a.persist(); err != nil {
				a.toast(err)
			}
			a.preview()
		} else {
			a.state()
		}
		a.reply(callback, object{"success": valid && err == nil, "photoGeneration": generation})
	}()
	return nil
}
