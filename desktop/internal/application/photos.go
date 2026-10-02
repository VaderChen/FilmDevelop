package application

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

type thumbnailWork struct {
	cancel context.CancelFunc
	done   chan struct{}
}
type browserState struct {
	Recent    []string `json:"recent,omitempty"`
	Version   int      `json:"version"`
	Directory string   `json:"directory"`
	Photo     string   `json:"photo"`
}

func (a *App) waitReady() error {
	select {
	case <-a.ready:
	case <-a.ctx.Done():
		return a.ctx.Err()
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.saving {
		return errors.New("請等待匯出完成")
	}
	return a.initError
}

func (a *App) OpenDirectory(path string) error { return a.openDirectory(path, "") }

func (a *App) openDirectory(path, preferred string) error {
	if err := a.waitReady(); err != nil {
		return err
	}
	a.openMu.Lock()
	defer a.openMu.Unlock()
	if err := a.persist(); err != nil {
		return err
	}
	a.mu.Lock()
	a.directoryScanning = true
	a.mu.Unlock()
	a.directoryState()
	directory, err := photos.Scan(a.ctx, path)
	a.mu.Lock()
	a.directoryScanning = false
	if err != nil {
		a.mu.Unlock()
		a.directoryState()
		return fmt.Errorf("無法讀取照片目錄：%w", err)
	}
	a.installDirectory(directory)
	a.mu.Unlock()
	a.directoryState()
	a.thumbnailCache.Prune()
	selected := ""
	if entry, ok := directory.ByID[photos.Identity(preferred)]; ok {
		selected = entry.Path
	} else if len(directory.Entries) > 0 {
		selected = directory.Entries[0].Path
	}
	if selected != "" {
		if err := a.openImage(selected); err != nil {
			return err
		}
	} else {
		a.mu.Lock()
		if a.cancel != nil {
			a.cancel()
		}
		a.revision++
		a.rendering = false
		a.source = ""
		a.imageKey = ""
		a.sourcePreview = ""
		a.cropPreview = ""
		a.outputPreview = ""
		a.loadingPreview = ""
		a.sourceWidth = 0
		a.sourceHeight = 0
		a.generation = identifier()
		a.undo = nil
		a.redo = nil
		a.recipes = clone(a.defaults)
		a.selected = "original"
		a.selectedCustom = ""
		a.customBase = nil
		_ = a.refreshUI()
		a.mu.Unlock()
		a.state()
	}
	return a.saveBrowser()
}

// OpenImage 同時建立所在目錄的列表，選檔與縮圖按鈕共用同一個開圖流程。
func (a *App) OpenImage(path string) error {
	if err := a.waitReady(); err != nil {
		return err
	}
	a.openMu.Lock()
	defer a.openMu.Unlock()
	path, err := photos.Canonical(path)
	if err != nil {
		return err
	}
	if err := a.persist(); err != nil {
		return err
	}
	a.mu.Lock()
	sameDirectory := a.directory.Path == filepath.Dir(path)
	a.mu.Unlock()
	if !sameDirectory {
		directory, err := photos.Scan(a.ctx, filepath.Dir(path))
		if err != nil {
			return err
		}
		a.mu.Lock()
		a.installDirectory(directory)
		a.mu.Unlock()
		a.directoryState()
	}
	if err := a.openImage(path); err != nil {
		return err
	}
	return a.saveBrowser()
}

// 呼叫方持有 mu；只清除派生縮圖，不清除使用者調整紀錄。
func (a *App) installDirectory(directory photos.Directory) {
	for _, work := range a.thumbnailWork {
		work.cancel()
	}
	a.directoryRevision++
	a.directory = directory
	a.thumbnailWork = map[string]*thumbnailWork{}
	a.thumbnails = map[string]string{}
	a.thumbnailFailed = map[string]bool{}
	a.directoryMessage = ""
	if len(directory.Entries) == 0 {
		a.directoryMessage = "此目錄沒有可讀取的照片或 RAW 檔案。"
	}
}

func (a *App) directoryPayload() object {
	items := make([]object, 0, len(a.directory.Entries))
	for _, entry := range a.directory.Entries {
		metadata := a.organization.Photos[entry.ID]
		if metadata.Tags == nil {
			metadata.Tags = []string{}
		}
		items = append(items, object{"id": entry.ID, "name": entry.Name, "modifiedAt": entry.ModifiedAt, "selected": entry.Path == a.source,
			"thumbnail": a.thumbnails[entry.ID], "isLoading": a.thumbnailWork[entry.ID] != nil, "failed": a.thumbnailFailed[entry.ID], "rating": metadata.Rating, "tags": metadata.Tags, "edited": a.organization.Edited[entry.ID]})
	}
	name := ""
	if a.directory.Path != "" {
		name = filepath.Base(a.directory.Path)
	}
	return object{"path": a.directory.Path, "name": name, "items": items, "totalCount": len(items), "categories": a.organization.Tags,
		"isScanning": a.directoryScanning, "isLoadingThumbnails": len(a.thumbnailWork) > 0, "message": a.directoryMessage}
}

func (a *App) directoryState() {
	a.mu.Lock()
	payload := a.directoryPayload()
	a.mu.Unlock()
	a.reply("handlePhotoDirectoryState", payload)
}

func (a *App) requestThumbnails(ids []string) error {
	if len(ids) > 48 {
		return errors.New("單次縮圖請求不可超過 48 張")
	}
	a.mu.Lock()
	if a.directoryScanning {
		a.mu.Unlock()
		return nil
	}
	wanted := map[string]bool{}
	for _, id := range ids {
		if _, ok := a.directory.ByID[id]; ok {
			wanted[id] = true
		}
	}
	// 初次顯影的底圖不受列表捲動取消；完成後沿用一般可視範圍快取策略。
	if a.source != "" && a.outputPreview == "" {
		wanted[photos.Identity(a.source)] = true
	}
	for id, work := range a.thumbnailWork {
		if !wanted[id] {
			work.cancel()
			delete(a.thumbnailWork, id)
		}
	}
	for id := range a.thumbnails {
		if !wanted[id] {
			delete(a.thumbnails, id)
		}
	}
	for _, entry := range a.directory.Entries {
		if !wanted[entry.ID] || a.thumbnails[entry.ID] != "" || a.thumbnailFailed[entry.ID] || a.thumbnailWork[entry.ID] != nil {
			continue
		}
		a.startThumbnail(entry)
	}
	a.mu.Unlock()
	a.directoryState()
	return nil
}

// 呼叫方持有 mu；列表與主預覽共用工作，不重複解碼同一張縮圖。
func (a *App) startThumbnail(entry photos.Entry) *thumbnailWork {
	if work := a.thumbnailWork[entry.ID]; work != nil {
		return work
	}
	ctx, cancel := context.WithCancel(a.ctx)
	work := &thumbnailWork{cancel: cancel, done: make(chan struct{})}
	a.thumbnailWork[entry.ID] = work
	a.workers.Add(1)
	go a.loadThumbnail(ctx, entry, a.directoryRevision, work)
	return work
}

// 呼叫方持有 mu；暖快取直接送出，冷快取等待原本列表的縮圖工作。
func (a *App) preparePreviewThumbnail() <-chan struct{} {
	if a.outputPreview != "" || a.loadingPreview != "" {
		return nil
	}
	entry, ok := a.directory.ByID[photos.Identity(a.source)]
	if !ok || a.thumbnailFailed[entry.ID] {
		return nil
	}
	if image := a.thumbnails[entry.ID]; image != "" {
		a.loadingPreview = image
		return nil
	}
	return a.startThumbnail(entry).done
}

func (a *App) loadThumbnail(ctx context.Context, entry photos.Entry, revision uint64, work *thumbnailWork) {
	defer a.workers.Done()
	defer work.cancel()
	defer close(work.done)
	select {
	case a.thumbnailGate <- struct{}{}:
		defer func() { <-a.thumbnailGate }()
	case <-ctx.Done():
		return
	}
	if ctx.Err() != nil {
		return
	}
	data := a.thumbnailCache.Read(entry.CacheKey)
	var err error
	if data == nil && entry.Unchanged() {
		data, err = a.thumbnailServices.Thumbnail(ctx, entry.Path)
	}
	if ctx.Err() != nil {
		return
	}
	if err == nil && len(data) > 0 && entry.Unchanged() {
		a.thumbnailCache.Write(entry.CacheKey, data)
	} else {
		data = nil
	}
	a.mu.Lock()
	if a.directoryRevision != revision || a.thumbnailWork[entry.ID] != work {
		a.mu.Unlock()
		return
	}
	delete(a.thumbnailWork, entry.ID)
	showPreview := false
	if len(data) > 0 {
		a.thumbnails[entry.ID] = "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(data)
		if a.source == entry.Path && a.outputPreview == "" && a.loadingPreview == "" {
			a.loadingPreview = a.thumbnails[entry.ID]
			showPreview = true
		}
	} else {
		a.thumbnailFailed[entry.ID] = true
	}
	a.mu.Unlock()
	a.directoryState()
	if showPreview {
		a.state()
	}
}

func (a *App) saveBrowser() error {
	a.mu.Lock()
	if a.directory.Path != "" {
		a.recent = append([]string{a.directory.Path}, without(a.recent, a.directory.Path)...)
		if len(a.recent) > 10 {
			a.recent = a.recent[:10]
		}
	}
	value := browserState{Version: 1, Directory: a.directory.Path, Photo: a.source, Recent: append([]string{}, a.recent...)}
	a.mu.Unlock()
	return a.store.SaveState("browser.json", value)
}

func (a *App) restoreBrowser() error {
	var value browserState
	exists, err := a.store.LoadState("browser.json", &value)
	if err != nil {
		return fmt.Errorf("無法恢復上次目錄，原紀錄已保留：%w", err)
	}
	a.mu.Lock()
	a.recent = value.Recent
	a.mu.Unlock()
	if !exists || value.Directory == "" {
		return nil
	}
	if value.Version != 1 {
		return errors.New("照片目錄紀錄版本不符")
	}
	if _, e := os.Stat(value.Photo); value.Photo != "" && e != nil {
		var cached struct {
			Path         string `json:"path"`
			OriginalPath string `json:"originalPath"`
			Fingerprint  string `json:"fingerprint"`
		}
		if found, e := a.store.LoadState("private-source.json", &cached); found && e == nil && cached.OriginalPath == value.Photo {
			if hash, e := storage.Fingerprint(a.ctx, cached.Path); e == nil && hash == cached.Fingerprint {
				return a.OpenImage(cached.Path)
			}
		}
	}
	return a.openDirectory(value.Directory, value.Photo)
}
