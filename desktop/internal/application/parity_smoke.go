//go:build enginesmoke

package application

import (
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"time"
)

// 僅供隔離 Smoke 呼叫已存在的應用流程，正式建置不包含這些入口。
func (a *App) RunParitySmoke(action, output string) error {
	switch action {
	case "models":
		directory := os.Getenv("FILMDEVELOP_SMOKE_MODEL_DIRECTORY")
		if directory == "" {
			return errors.New("未提供實際 GGUF 測試模型")
		}
		a.mu.Lock()
		a.modelSettings.Directory = directory
		a.mu.Unlock()
		if err := a.rescanModels(a.ctx, directory); err != nil {
			return err
		}
		a.state()
		return nil
	case "portrait":
		path := filepath.Join(filepath.Dir(output), "portrait.jpg")
		f, err := os.Create(path)
		if err != nil {
			return err
		}
		photo := image.NewRGBA(image.Rect(0, 0, 80, 120))
		for y := 0; y < 120; y++ {
			for x := 0; x < 80; x++ {
				photo.SetRGBA(x, y, color.RGBA{R: uint8(x * 3), G: uint8(y * 2), B: 80, A: 255})
			}
		}
		err = jpeg.Encode(f, photo, nil)
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		return a.OpenImage(path)
	case "repair":
		a.mu.Lock()
		ctx, cancel := context.WithCancel(a.ctx)
		a.cancel = cancel
		a.repairing, a.cancellingRepair = true, false
		a.repairProgress = object{"received": 25, "total": 100, "preparing": false}
		a.repairStep = "首次使用：正在下載修復模型"
		a.mu.Unlock()
		a.state()
		a.workers.Add(1)
		go func() {
			defer a.workers.Done()
			defer cancel()
			<-ctx.Done()
			time.Sleep(400 * time.Millisecond)
			a.mu.Lock()
			a.repairing, a.cancellingRepair = false, false
			a.repairProgress = nil
			a.repairStep = ""
			a.mu.Unlock()
			a.state()
		}()
		return nil
	case "batch", "duplicate":
		a.mu.Lock()
		paths := []string{}
		if action == "duplicate" {
			paths = append(paths, a.source)
		} else {
			for _, entry := range a.directory.Entries {
				paths = append(paths, entry.Path)
			}
		}
		a.mu.Unlock()
		operation := "export"
		if action == "duplicate" {
			operation = "duplicate"
		}
		return a.batchPhotos(paths, operation, filepath.Dir(output))
	case "export-failure":
		return a.ExportImage(filepath.Join(output, "不可用.jpg"))
	case "ai":
		a.mu.Lock()
		ctx, cancel := context.WithCancel(a.ctx)
		a.cancel = cancel
		a.computing = true
		a.computationCompleted = 2
		a.computationStep = aiComputationItems[2]
		a.mu.Unlock()
		a.state()
		a.workers.Add(1)
		go func() {
			defer a.workers.Done()
			defer cancel()
			<-ctx.Done()
			// 模擬原生工作在收到取消後安全收尾。
			time.Sleep(100 * time.Millisecond)
			a.mu.Lock()
			a.computing = false
			a.cancellingComputation = false
			a.computationCompleted = 0
			a.computationStep = ""
			a.mu.Unlock()
			a.state()
		}()
		return nil
	}
	return errors.New("未知的移植 Smoke 操作")
}
