package application

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// UI 與 MCP 共用設定快照、取代檢查及原有顯影動畫。呼叫方管理 saving。
func (a *App) renderExport(ctx context.Context, job contract.RenderJob, overwrite bool) (data json.RawMessage, err error) {
	a.mu.Lock()
	image := a.outputPreview
	logical := a.logicalSourcePath()
	width, height := a.sourceWidth, a.sourceHeight
	a.mu.Unlock()
	id, started := identifier(), time.Now()
	fields := recipeFields(job.Recipe)
	profile := fmt.Sprintf("%s:%s:%d:%t:%v:%v:%v", job.Recipe.Style, job.Output.Format, job.Output.BitDepth, job.Recipe.DetectSubject, fields["backgroundBlur"], fields["denoise"], fields["hdrAmount"])
	a.reply("handleExportDevelopment", object{"phase": "begin", "id": id, "image": image,
		"timing": object{"profile": profile, "workUnits": max(.25, float64(width)*float64(height)*(1+float64(job.Output.BitDepth)/8)/1_000_000)}})
	defer func() {
		if err != nil {
			a.reply("handleExportDevelopment", object{"phase": "cancel", "id": id})
		}
	}()
	path, err := filepath.Abs(job.Output.Path)
	if err != nil {
		return nil, err
	}
	old, statErr := os.Lstat(path)
	if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return nil, statErr
	}
	for _, source := range []string{job.Input.Path, logical} {
		if source == "" {
			continue
		}
		absolute, e := filepath.Abs(source)
		if e != nil {
			return nil, e
		}
		info, _ := os.Stat(source)
		targetInfo, _ := os.Stat(path)
		if path == absolute || info != nil && targetInfo != nil && os.SameFile(info, targetInfo) {
			return nil, errors.New("不得覆寫來源照片")
		}
	}
	if old != nil {
		if !overwrite {
			return nil, errors.New("輸出已存在")
		}
		if !old.Mode().IsRegular() {
			return nil, errors.New("輸出不是一般檔案")
		}
		directory, e := os.MkdirTemp(filepath.Dir(path), ".filmdevelop-export-")
		if e != nil {
			return nil, e
		}
		defer os.RemoveAll(directory)
		job.Output.Path = filepath.Join(directory, filepath.Base(path))
	}
	data, err = a.services.RenderWithStages(ctx, job, func(stage string, progress float64) {
		a.reply("handleExportDevelopment", object{"phase": "progress", "id": id, "stage": stage, "progress": progress})
	})
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if old != nil {
		current, e := os.Lstat(path)
		if e != nil || !os.SameFile(old, current) || old.Size() != current.Size() || !old.ModTime().Equal(current.ModTime()) {
			return nil, errors.New("目的檔案已被其他操作修改")
		}
		if err = os.Rename(job.Output.Path, path); err != nil {
			return nil, fmt.Errorf("取代匯出檔案失敗：%w", err)
		}
	}
	a.mu.Lock()
	a.lastExportedPath = path
	a.mu.Unlock()
	a.reply("handleExportDevelopment", object{"phase": "complete", "id": id, "durationMs": float64(time.Since(started).Microseconds()) / 1000})
	return data, nil
}
