package application

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/text/unicode/norm"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type photoMetadata struct {
	Rating int      `json:"rating"`
	Tags   []string `json:"tags"`
}
type organization struct {
	LegacyOrganizationImported bool                     `json:"legacyOrganizationImported,omitempty"`
	Version                    int                      `json:"version"`
	Tags                       []string                 `json:"tags"`
	Photos                     map[string]photoMetadata `json:"photos"`
	Edited                     map[string]bool          `json:"edited,omitempty"`
}

// 分類與分級獨立於編輯標記遷移；Go 曾開圖並不代表已匯入 Swift 資料。
// 只補缺少的照片，保留 Go 已保存的分級、分類及明確清除結果。
func (a *App) loadOrganization() error {
	next := organization{Version: 1, Tags: []string{}, Photos: map[string]photoMetadata{}, Edited: map[string]bool{}}
	found, err := a.store.LoadState("organization.json", &next)
	if err != nil {
		return err
	}
	if next.Tags == nil {
		next.Tags = []string{}
	}
	if next.Photos == nil {
		next.Photos = map[string]photoMetadata{}
	}
	if next.Edited == nil {
		next.Edited = map[string]bool{}
	}
	if err = validateOrganization(next); err != nil {
		return err
	}
	if !found && a.legacyPhotoDirectory != "" {
		next.Edited, err = a.legacyEditedPhotos()
		if err != nil {
			return err
		}
	}
	if !next.LegacyOrganizationImported && a.legacyPhotoDirectory != "" {
		data, readErr := readBounded(filepath.Join(filepath.Dir(a.legacyPhotoDirectory), "PhotoOrganization.json"), 16*1024*1024)
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return readErr
		}
		if readErr == nil {
			var legacy organization
			if err = json.Unmarshal(data, &legacy); err != nil {
				return err
			}
			if legacy.Tags == nil || legacy.Photos == nil {
				return errors.New("舊照片分類資料不完整")
			}
			if err = validateOrganization(legacy); err != nil {
				return err
			}
			for _, tag := range legacy.Tags {
				if !contains(next.Tags, tag) {
					next.Tags = append(next.Tags, tag)
				}
			}
			for key, metadata := range legacy.Photos {
				if _, exists := next.Photos[key]; !exists {
					next.Photos[key] = metadata
				}
			}
			// 和資料一併原子寫入，避免之後清除分類又被舊版重新匯入。
			next.LegacyOrganizationImported = true
			if err = a.store.SaveState("organization.json", next); err != nil {
				return err
			}
		}
	}
	a.organization = next
	return nil
}

func validateOrganization(value organization) error {
	if value.Version != 1 {
		return errors.New("照片分類資料版本不符")
	}
	tags := map[string]bool{}
	for _, tag := range value.Tags {
		if strings.TrimSpace(tag) == "" || tags[tag] {
			return errors.New("照片分類資料不符")
		}
		tags[tag] = true
	}
	for _, metadata := range value.Photos {
		if metadata.Rating < 0 || metadata.Rating > 5 {
			return errors.New("照片分級資料不符")
		}
		seen := map[string]bool{}
		for _, tag := range metadata.Tags {
			if !tags[tag] || seen[tag] {
				return errors.New("照片分類資料不符")
			}
			seen[tag] = true
		}
	}
	return nil
}
func (a *App) markEdited() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.source == "" {
		return nil
	}
	edited := a.selected != "original" || a.selectedCustom != "" || len(a.manual.PrintControls) > 0
	for id, r := range a.recipes {
		if string(r.Adjustment) != string(a.defaults[id].Adjustment) || string(r.RepairPatches) != "[]" {
			edited = true
			break
		}
	}
	next := clone(a.organization)
	if next.Edited == nil {
		next.Edited = map[string]bool{}
	}
	next.Edited[photos.Identity(a.source)] = edited
	if err := a.store.SaveState("organization.json", next); err != nil {
		return err
	}
	a.organization = next
	return nil
}
func (a *App) recentDirectories(message object) error {
	a.mu.Lock()
	recent := append([]string{}, a.recent...)
	a.mu.Unlock()
	choices := []contextMenuItem{}
	for i, p := range recent {
		choices = append(choices, contextMenuItem{ID: strconv.Itoa(i), Label: p, Literal: true})
	}
	if len(choices) == 0 {
		choices = append(choices, contextMenuItem{Label: "尚無最近開啟的目錄", Disabled: true})
	}
	return a.showMenu("最近開啟的目錄", choices, message, func(value string) error { n, _ := strconv.Atoi(value); return a.OpenDirectory(recent[n]) })
}
func (a *App) selectionPaths(message object) ([]string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var ids []string
	data, _ := json.Marshal(message["ids"])
	_ = json.Unmarshal(data, &ids)
	if len(ids) == 0 {
		if id := stringValue(message, "id"); id != "" {
			ids = []string{id}
		}
	}
	paths := []string{}
	seen := map[string]bool{}
	for _, id := range ids {
		e, ok := a.directory.ByID[id]
		if !ok {
			return nil, errors.New("照片已不在目前目錄")
		}
		if !seen[id] {
			paths = append(paths, e.Path)
			seen[id] = true
		}
	}
	if len(paths) == 0 && a.source != "" {
		paths = append(paths, a.source)
	}
	if len(paths) == 0 {
		return nil, errors.New("請先選取照片")
	}
	return paths, nil
}
func (a *App) previewMenu(message object) error {
	paths, err := a.selectionPaths(message)
	if err != nil {
		return err
	}
	a.mu.Lock()
	copied := a.copiedRecipe != nil
	hasUndo, hasRedo := len(a.undo) > 0, len(a.redo) > 0
	a.mu.Unlock()
	items := []contextMenuItem{}
	preview := stringValue(message, "id") == ""
	if preview {
		items = append(items, contextMenuItem{ID: "undoEdit", Label: "上一步", Disabled: !hasUndo}, contextMenuItem{ID: "redoEdit", Label: "下一步", Disabled: !hasRedo}, menuSeparator(),
			contextMenuItem{ID: "histogram", Label: "顯示直方圖"}, contextMenuItem{Label: "裁切", Items: []contextMenuItem{{ID: "source", Label: "原始比例"}, {ID: "free", Label: "自由裁切"}}})
	}
	if len(paths) == 1 {
		items = append(items, contextMenuItem{ID: "exif", Label: "顯示 EXIF"})
	}
	if len(items) > 0 {
		items = append(items, menuSeparator())
	}
	organizationItems, actions := a.organizationMenus(paths)
	items = append(items, organizationItems...)
	items = append(items, menuSeparator())
	if len(paths) == 1 {
		items = append(items, contextMenuItem{ID: "copy", Label: "複製調整參數"})
	}
	items = append(items, contextMenuItem{ID: "apply", Label: "套用調整參數", Disabled: !copied}, contextMenuItem{ID: "reset", Label: "恢復預設值"}, menuSeparator())
	if len(paths) == 1 {
		items = append(items, contextMenuItem{ID: "duplicate", Label: "複製照片"}, contextMenuItem{ID: "reveal", Label: "顯示於檔案管理員"})
	}
	items = append(items, contextMenuItem{ID: "export", Label: "匯出照片"}, menuSeparator(), contextMenuItem{ID: "trash", Label: "移到垃圾桶"})
	return a.showMenu("照片操作", items, message, func(command string) error {
		if action := actions[command]; action != nil {
			return action()
		}
		switch command {
		case "exif":
			return a.showEXIF(paths[0])
		case "reveal":
			_, e := a.services.Native(a.ctx, "reveal", contract.FileRequest{Path: paths[0]}, nil)
			return e
		case "trash":
			return a.showDialog("移到垃圾桶", fmt.Sprintf("將選取的 %d 張原始照片移到系統垃圾桶？", len(paths)), "", []dialogChoice{{ID: "trash", Label: "移到垃圾桶", Role: "destructive"}}, func(string) error { return a.trashPhotos(paths) })
		case "export":
			if preview {
				a.reply("handleDesktopCommand", "exportImage")
				return nil
			}
			dir, e := wruntime.OpenDirectoryDialog(a.ctx, wruntime.OpenDialogOptions{Title: "選取批次匯出目錄", DefaultDirectory: a.preferences.ExportDirectory})
			if e != nil || dir == "" {
				return e
			}
			return a.batchPhotos(paths, "export", dir)
		case "copy", "apply", "reset", "duplicate":
			return a.batchPhotos(paths, command, "")
		default:
			a.reply("handlePreviewMenu", object{"command": command})
			return nil
		}
	})
}

func (a *App) organizationMenus(paths []string) ([]contextMenuItem, map[string]func() error) {
	a.mu.Lock()
	organization := clone(a.organization)
	a.mu.Unlock()
	tags := append([]string{}, organization.Tags...)
	sort.Strings(tags)
	actions := map[string]func() error{}
	ratings, categories := []contextMenuItem{}, []contextMenuItem{}
	for value := 0; value <= 5; value++ {
		label, count := strings.Repeat("★", value), 0
		if value == 0 {
			label = "未分級"
		}
		for _, path := range paths {
			if organization.Photos[photos.Identity(path)].Rating == value {
				count++
			}
		}
		id := "rating:" + strconv.Itoa(value)
		ratings = append(ratings, contextMenuItem{ID: id, Label: label, Checked: menuSelection(count, len(paths))})
		actions[id] = func() error { return a.changeMetadata(paths, "rating", value) }
	}
	removal := []contextMenuItem{}
	anyTags := false
	for index, tag := range tags {
		count, used := 0, false
		for _, path := range paths {
			if contains(organization.Photos[photos.Identity(path)].Tags, tag) {
				count++
				anyTags = true
			}
		}
		for _, photo := range organization.Photos {
			if contains(photo.Tags, tag) {
				used = true
				break
			}
		}
		id, removeID := "tag:"+strconv.Itoa(index), "removeTag:"+strconv.Itoa(index)
		categories = append(categories, contextMenuItem{ID: id, Label: tag, Literal: true, Checked: menuSelection(count, len(paths))})
		removal = append(removal, contextMenuItem{ID: removeID, Label: tag, Literal: true, Disabled: used})
		actions[id] = func() error { return a.changeMetadata(paths, "tag", tag) }
		actions[removeID] = func() error { return a.changeMetadata(nil, "remove", tag) }
	}
	if len(categories) > 0 {
		categories = append(categories, menuSeparator())
	}
	categories = append(categories, contextMenuItem{ID: "newTag", Label: "新增分類…"},
		contextMenuItem{ID: "clearTags", Label: "清除照片分類", Disabled: !anyTags},
		contextMenuItem{Label: "移除未使用的分類…", Disabled: len(removal) == 0, Items: removal})
	actions["newTag"] = func() error {
		return a.showDialog("新增分類", "為選取的照片加入分類。", "", nil, func(tag string) error { return a.changeMetadata(paths, "tag", tag) })
	}
	actions["clearTags"] = func() error { return a.changeMetadata(paths, "clear", nil) }
	return []contextMenuItem{{Label: "分級", Items: ratings}, {Label: "分類", Items: categories}}, actions
}
func (a *App) changeMetadata(paths []string, operation string, value any) error {
	a.mu.Lock()
	next := clone(a.organization)
	tag := ""
	present := true
	if operation == "tag" || operation == "remove" {
		var err error
		tag, err = validName(value.(string), 40)
		if err != nil {
			a.mu.Unlock()
			return err
		}
		for _, t := range next.Tags {
			if strings.EqualFold(norm.NFC.String(t), norm.NFC.String(tag)) {
				tag = t
				break
			}
		}
		present = false
		for _, p := range paths {
			if !contains(next.Photos[photos.Identity(p)].Tags, tag) {
				present = true
			}
		}
		if operation == "tag" && present && !contains(next.Tags, tag) {
			next.Tags = append(next.Tags, tag)
		}
		if operation == "remove" {
			for _, m := range next.Photos {
				if contains(m.Tags, tag) {
					a.mu.Unlock()
					return errors.New("此分類仍有照片，請先移除照片的分類標記")
				}
			}
			next.Tags = without(next.Tags, tag)
		}
	}
	for _, p := range paths {
		key := photos.Identity(p)
		m := next.Photos[key]
		if m.Tags == nil {
			m.Tags = []string{}
		}
		switch operation {
		case "rating":
			m.Rating = value.(int)
		case "clear":
			m.Tags = []string{}
		case "tag":
			m.Tags = without(m.Tags, tag)
			if present {
				m.Tags = append(m.Tags, tag)
			}
		}
		sort.Strings(m.Tags)
		next.Photos[key] = m
	}
	err := a.store.SaveState("organization.json", next)
	if err == nil {
		a.organization = next
	}
	a.mu.Unlock()
	if err == nil {
		a.directoryState()
	}
	return err
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func without(values []string, value string) []string {
	out := []string{}
	for _, v := range values {
		if v != value {
			out = append(out, v)
		}
	}
	return out
}
func (a *App) photoDocument(ctx context.Context, path string) (string, *storage.Document, error) {
	fingerprint, err := storage.Fingerprint(ctx, path)
	if err != nil {
		return "", nil, err
	}
	key := storage.PhotoKey(path, fingerprint)
	saved, err := a.store.Load(key)
	if err != nil {
		return "", nil, err
	}
	if saved == nil {
		saved, err = a.store.Load(fingerprint)
		if err != nil {
			return "", nil, err
		}
	}
	if saved == nil || legacyPhotoPlaceholder(saved) {
		legacy, err := a.legacyPhotoDocument(fingerprint, path)
		if err != nil {
			return "", nil, err
		}
		if legacy != nil {
			saved = legacy
		}
	}
	if saved == nil {
		saved = &storage.Document{Fresh: true, Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{}, Manual: &storage.ManualAdjustments{PrintControls: []string{}, HasCompleteHistory: true}}
	}
	originalPath := ""
	if saved.Source != nil {
		originalPath = saved.Source.OriginalPath
	}
	saved.Source = &storage.PhotoSource{Path: path, Fingerprint: fingerprint, OriginalPath: originalPath}
	if saved.SubjectMask != nil {
		if saved.SubjectMask.SourceFingerprint != fingerprint {
			saved.SubjectMask = nil
		} else if e := a.store.ValidateMaskAsset(saved.SubjectMask); e != nil {
			a.migrationProblem(path+" 主體遮罩", e, "")
			saved.SubjectMask = nil
		}
	}
	return key, saved, nil
}
func (a *App) batchPhotos(paths []string, operation, directory string) error {
	if err := a.persist(); err != nil {
		return err
	}
	a.mu.Lock()
	if a.saving {
		a.mu.Unlock()
		return errors.New("已有作業進行中")
	}
	copied := clone(a.copiedRecipe)
	if operation == "apply" && copied == nil {
		a.mu.Unlock()
		return errors.New("尚未複製調整參數")
	}
	a.invalidatePreview()
	ctx, cancel := context.WithCancel(a.ctx)
	// 批次生命週期獨立於預覽；套用目前照片的配方不能取消後續照片。
	a.cancel = nil
	a.saving = true
	settings := a.exportSettings
	template := a.job("", a.defaults["original"], false)
	a.batch = object{"id": identifier(), "title": "照片批次處理", "total": len(paths), "current": 1, "progress": 0, "succeeded": 0, "failed": 0}
	if operation == "export" {
		a.batch["title"], a.batch["stage"] = "正在批次輸出照片", "準備輸出"
	}
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		failures := []string{}
		success := 0
		currentChanged := false
		rescan := false
		duplicateTarget := ""
		for i, path := range paths {
			if ctx.Err() != nil {
				break
			}
			stage := "正在處理"
			if operation == "export" {
				stage = "正在讀取圖片"
			}
			a.batchProgress(i, filepath.Base(path), stage, 0, success, len(failures))
			key, doc, err := a.photoDocument(ctx, path)
			if err == nil {
				switch operation {
				case "copy":
					for id, r := range doc.Recipes {
						r.RepairPatches = json.RawMessage(`[]`)
						doc.Recipes[id] = r
					}
					a.mu.Lock()
					a.copiedRecipe = clone(doc)
					a.mu.Unlock()
				case "reset", "apply":
					next := &storage.Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{}, Manual: &storage.ManualAdjustments{PrintControls: []string{}, HasCompleteHistory: true}}
					if operation == "apply" {
						next = clone(copied)
						var patches json.RawMessage
						for _, r := range doc.Recipes {
							if string(r.RepairPatches) != "[]" {
								patches = r.RepairPatches
								break
							}
						}
						if len(patches) > 0 {
							// 修復屬於目標照片；即使複製的是無調整原片也保留。
							for id, r := range a.defaults {
								if _, ok := next.Recipes[id]; !ok {
									next.Recipes[id] = r
								}
							}
							for id, r := range next.Recipes {
								r.RepairPatches = patches
								next.Recipes[id] = r
							}
						}
					}
					next.Source = clone(doc.Source)
					next.SubjectMask = clone(doc.SubjectMask)
					if operation == "reset" {
						next.SubjectMask = nil
					}
					err = a.store.Save(key, *next)
					if err == nil {
						a.mu.Lock()
						if path == a.source {
							if operation == "reset" {
								a.clearHistory()
							} else {
								a.pushHistory()
							}
							a.recipes = clone(a.defaults)
							for id, r := range next.Recipes {
								a.recipes[id] = r
							}
							a.subjectMask = clone(next.SubjectMask)
							a.forceSubject, a.skipSubject = false, false
							a.sourceIdentity = clone(next.Source)
							a.selected = next.Selected
							a.selectedCustom = next.CustomID
							a.customBase = clone(next.CustomBase)
							a.detachUnavailableFilm()
							a.manual = storage.ManualAdjustments{}
							if next.Manual != nil {
								a.manual = clone(*next.Manual)
							}
							err = a.refreshUI()
							currentChanged = true
						}
						a.organization.Edited[photos.Identity(path)] = operation != "reset"
						a.mu.Unlock()
					}
				case "duplicate":
					target := uniquePath(filepath.Dir(path), strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))+" copy", filepath.Ext(path))
					err = copyPhoto(ctx, path, target)
					if err == nil {
						fingerprint, e := storage.Fingerprint(ctx, target)
						if e == nil {
							doc.Source = &storage.PhotoSource{Path: target, Fingerprint: fingerprint}
							err = a.store.Save(storage.PhotoKey(target, fingerprint), *doc)
						} else {
							err = e
						}
						if err != nil {
							_ = os.Remove(target)
						} else {
							rescan = true
							duplicateTarget = target
						}
					}
				case "export":
					recipe, ok := doc.Recipes[doc.Selected]
					if !ok {
						recipe = clone(a.defaults[doc.Selected])
					}
					recipe, err = a.services.NormalizeRecipe(recipe)
					if err == nil {
						job := template
						job.Input.Path = path
						job.Recipe = recipe
						job.SubjectMask = nil
						if a.validSubjectMask(doc.SubjectMask, doc.Source, recipe) {
							job.SubjectMask = &contract.SubjectMaskInput{Path: a.store.MaskPath(doc.SubjectMask), Sha256: doc.SubjectMask.SHA256}
						}
						job.Recipe.DetectSubject = requiresSubject(recipe) || doc.SubjectMask != nil
						logical := path
						if doc.Source != nil && doc.Source.OriginalPath != "" {
							logical = doc.Source.OriginalPath
						}
						target := uniquePath(directory, exportName(logical), "."+settings.fileExtension())
						job.Output = settings.output(target)
						_, err = a.services.RenderWithStages(ctx, job, func(stage string, value float64) {
							label, fraction := "正在處理照片", .15+.65*value
							switch stage {
							case "encode":
								label, fraction = "正在編碼照片", .8+.15*value
							case "write":
								// 完成發布及統計前，保留最後 5% 給寫入。
								label, fraction = "正在儲存照片", .95
							}
							a.batchProgress(i, filepath.Base(path), label, fraction, success, len(failures))
						})
						if err == nil {
							a.mu.Lock()
							a.lastExportedPath = target
							a.mu.Unlock()
						}
					}
				}
			}
			if err != nil {
				failures = append(failures, filepath.Base(path)+"："+err.Error())
			} else {
				success++
			}
			a.batchProgress(i, filepath.Base(path), "處理完成", 1, success, len(failures))
		}
		a.mu.Lock()
		a.saving = false
		a.batch = nil
		organization := clone(a.organization)
		folder, source := a.directory.Path, a.source
		a.mu.Unlock()
		if err := a.store.SaveState("organization.json", organization); err != nil {
			failures = append(failures, err.Error())
		}
		if rescan {
			if d, e := photos.Scan(a.ctx, folder); e == nil {
				a.mu.Lock()
				a.installDirectory(d)
				a.mu.Unlock()
			}
		}
		a.state()
		a.directoryState()
		if duplicateTarget != "" && ctx.Err() == nil {
			if err := a.OpenImage(duplicateTarget); err != nil {
				failures = append(failures, err.Error())
			} else if err := a.waitPreview(a.ctx); err == nil {
				a.mu.Lock()
				selected := a.source == duplicateTarget
				a.mu.Unlock()
				if selected {
					a.reply("handleFocusDirectoryPhoto", object{"path": filepath.Dir(duplicateTarget), "name": filepath.Base(duplicateTarget)})
				}
			}
		} else if currentChanged && source != "" {
			a.preview()
		}
		a.toast(fmt.Errorf("已完成 %d／%d 張照片。%s", success, len(paths), strings.Join(failures, "\n")))
	}()
	return nil
}
func (a *App) batchProgress(index int, name, stage string, fraction float64, success, failed int) {
	if math.IsNaN(fraction) || math.IsInf(fraction, 0) {
		return
	}
	a.mu.Lock()
	if a.batch == nil {
		a.mu.Unlock()
		return
	}
	total, _ := a.batch["total"].(int)
	current, _ := a.batch["current"].(int)
	previous, _ := a.batch["progress"].(float64)
	progress := min(1.0, max(0.0, (float64(index)+min(1.0, max(0.0, fraction)))/float64(max(1, total))))
	// 沿用 Swift 的單張 1% 合併門檻；階段或統計改變仍立即回報。
	if index < current-1 || index >= total || progress < previous ||
		(index+1 == current && stage == a.batch["stage"] && success == a.batch["succeeded"] && failed == a.batch["failed"] && (progress-previous)*float64(total) < .01) {
		a.mu.Unlock()
		return
	}
	a.batch["current"] = index + 1
	a.batch["filename"] = name
	a.batch["stage"] = stage
	a.batch["progress"] = progress
	a.batch["succeeded"] = success
	a.batch["failed"] = failed
	p := clone(a.batch)
	a.mu.Unlock()
	a.reply("handleBatchExportProgress", p)
}
func uniquePath(directory, stem, ext string) string {
	for n := 1; ; n++ {
		name := stem
		if n > 1 {
			name = fmt.Sprintf("%s (%d)", stem, n)
		}
		p := filepath.Join(directory, name+ext)
		if _, err := os.Lstat(p); err != nil {
			return p
		}
	}
}
func copyPhoto(ctx context.Context, source, target string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		out.Close()
		if !complete {
			os.Remove(target)
		}
	}()
	buffer := make([]byte, 1024*1024)
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		n, e := in.Read(buffer)
		if n > 0 {
			if _, err = out.Write(buffer[:n]); err != nil {
				return err
			}
		}
		if errors.Is(e, io.EOF) {
			break
		}
		if e != nil {
			return e
		}
	}
	if err = out.Sync(); err != nil {
		return err
	}
	if err = out.Close(); err != nil {
		return err
	}
	complete = true
	return nil
}
func (a *App) trashPhotos(paths []string) error {
	if err := a.persist(); err != nil {
		return err
	}
	a.mu.Lock()
	folder, preferred := a.directory.Path, a.source
	a.mu.Unlock()
	failures := []string{}
	for _, p := range paths {
		if _, err := a.services.Native(a.ctx, "trash", contract.FileRequest{Path: p}, nil); err != nil {
			failures = append(failures, filepath.Base(p)+"："+err.Error())
		}
	}
	if err := a.openDirectory(folder, preferred); err != nil {
		return err
	}
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "\n"))
	}
	return nil
}
