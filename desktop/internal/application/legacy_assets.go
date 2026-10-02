package application

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

func repairDigest(raw json.RawMessage) string {
	var value any
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || value == nil {
		value = []any{}
	}
	return sourceHash(value)
}

var decorationKeys = []string{"frameEnabled", "frameStyle", "dateEnabled", "dateStyle"}

func (a *App) migrateDecorations(value any) error {
	data, _ := json.Marshal(value)
	var saved map[string]json.RawMessage
	if json.Unmarshal(data, &saved) != nil {
		return errors.New("舊底片装飾偏好格式錯誤")
	}
	next := object{}
	for id, adjustment := range saved {
		r, err := a.services.NormalizeRecipe(contract.Recipe{Version: 1, Style: id, Adjustment: adjustment, RepairPatches: json.RawMessage(`[]`)})
		if err != nil {
			a.migrationProblem("styleAdjustments.v1/"+id, err, "")
			continue
		}
		fields, decoration := recipeFields(r), object{}
		for _, key := range decorationKeys {
			if value, ok := fields[key]; ok {
				decoration[key] = value
			}
		}
		next[id] = decoration
	}
	return a.mergeLegacyState("decorations.json", next)
}
func (a *App) loadDecorations() error {
	a.decorations = map[string]object{}
	_, err := a.store.LoadState("decorations.json", &a.decorations)
	return err
}
func (a *App) newPhotoRecipes() map[string]contract.Recipe {
	next := clone(a.defaults)
	for id, decoration := range a.decorations {
		r, ok := next[id]
		if !ok {
			continue
		}
		fields := recipeFields(r)
		for _, key := range decorationKeys {
			if value, ok := decoration[key]; ok {
				fields[key] = value
			}
		}
		r.Adjustment, _ = json.Marshal(fields)
		if normalized, err := a.services.NormalizeRecipe(r); err == nil {
			next[id] = normalized
		}
	}
	return next
}

// 僅在使用者調整後保存；讀取舊照片不能倒灌其曝光或裁切到下一張。
func (a *App) rememberDecorations() error {
	a.mu.Lock()
	next := clone(a.decorations)
	if next == nil {
		next = map[string]object{}
	}
	fields := recipeFields(a.recipes[a.selected])
	decoration := object{}
	for _, key := range decorationKeys {
		decoration[key] = fields[key]
	}
	next[a.selected] = decoration
	a.mu.Unlock()
	if err := a.store.SaveState("decorations.json", next); err != nil {
		return err
	}
	a.mu.Lock()
	a.decorations = next
	a.mu.Unlock()
	return nil
}

// 將所有舊記錄（包括暫時找不到原圖者）保存在 Go 資料目錄。
// 原 Swift 檔案不改寫；每個檔案先落盤才建立清冊。
func (a *App) archiveLegacyPhotos() error {
	destination := filepath.Join(a.store.Root(), "legacy", "PhotoEdits")
	original := a.legacyPhotoDirectory
	if original != "" && filepath.Clean(original) != filepath.Clean(destination) {
		entries, err := os.ReadDir(original)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		inventory := object{}
		_, _ = a.store.LoadState("legacy-assets.json", &inventory)
		for _, entry := range entries {
			if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
				continue
			}
			name := entry.Name()
			if name != "edited-photos.json" {
				key := strings.TrimSuffix(strings.TrimSuffix(name, ".json"), ".mask.rgba")
				if value, err := hex.DecodeString(key); err != nil || len(value) != 32 || (name != key+".json" && name != key+".mask.rgba") {
					continue
				}
			}
			if _, err := os.Stat(filepath.Join(destination, name)); err == nil {
				continue
			}
			data, err := readBounded(filepath.Join(original, name), 268435472)
			if err != nil {
				a.migrationProblem(name, err, original)
				continue
			}
			if err := a.store.PreserveFile(filepath.Join("legacy", "PhotoEdits", name), data); err != nil {
				return err
			}
			inventory[name] = object{"hash": sha256Bytes(data), "bytes": len(data), "source": filepath.Join(original, name)}
			if strings.HasSuffix(name, ".mask.rgba") {
				if _, _, e := storage.ValidateMask(data); e != nil {
					a.migrationProblem(name, e, filepath.Join(destination, name))
				}
			}
		}
		if len(inventory) > 0 {
			if err := a.store.SaveState("legacy-assets.json", inventory); err != nil {
				return err
			}
		}
		for _, name := range []string{"PhotoOrganization.json", "CustomFilms.json"} {
			if data, e := readBounded(filepath.Join(filepath.Dir(original), name), 64*1024*1024); e == nil {
				if _, e := os.Stat(filepath.Join(a.store.Root(), "legacy", name)); errors.Is(e, os.ErrNotExist) {
					if e = a.store.PreserveFile(filepath.Join("legacy", name), data); e != nil {
						return e
					}
				}
			}
		}
	}
	if _, err := os.Stat(destination); err != nil {
		return nil
	}
	a.legacyPhotoDirectory = destination
	// 已知目錄逐張建立路徑＋內容清冊；離線記錄保留於 legacy，待重新定位。
	var browser browserState
	_, _ = a.store.LoadState("browser.json", &browser)
	directories := append([]string{browser.Directory}, browser.Recent...)
	if p, ok := a.legacySettings["lastPhotoDirectoryPath.v1"].(string); ok {
		directories = append(directories, p)
	}
	seen := map[string]bool{}
	index := map[string]object{}
	_, _ = a.store.LoadState("photo-source-index.json", &index)
	if index == nil {
		index = map[string]object{}
	}
	for _, directory := range directories {
		if directory == "" || seen[directory] {
			continue
		}
		seen[directory] = true
		scan, err := photos.Scan(a.ctx, directory)
		if err != nil {
			a.migrationProblem(directory, fmt.Errorf("照片目錄尚未定位：%w", err), destination)
			continue
		}
		for _, entry := range scan.Entries {
			if err := a.ctx.Err(); err != nil {
				return err
			}
			signature := fmt.Sprintf("%d:%d", entry.Size, entry.ModifiedNS)
			if old := index[entry.Path]; old != nil && old["signature"] == signature {
				if key, ok := old["key"].(string); ok {
					if _, err := os.Stat(filepath.Join(a.store.Root(), "photos", key+".json")); err == nil {
						continue
					}
				}
			}
			fingerprint := ""
			if old := index[entry.Path]; old != nil && old["signature"] == signature {
				fingerprint, _ = old["fingerprint"].(string)
			}
			var err error
			if fingerprint == "" {
				fingerprint, err = storage.Fingerprint(a.ctx, entry.Path)
			}
			if err != nil {
				a.migrationProblem(entry.Path, err, "")
				continue
			}
			index[entry.Path] = object{"signature": signature, "fingerprint": fingerprint}
			hasDocument := false
			for _, candidate := range a.legacySourcePaths(entry.Path) {
				if _, e := os.Stat(filepath.Join(destination, storage.PhotoKey(candidate, "sha256:"+fingerprint)+".json")); e == nil {
					hasDocument = true
					break
				}
			}
			if !hasDocument {
				_, hasMetadata := a.organization.Photos[entry.ID]
				_, hasEdited := a.organization.Edited[entry.ID]
				if !hasMetadata && !hasEdited {
					continue
				}
			}
			key, doc, err := a.photoDocument(a.ctx, entry.Path)
			if err != nil {
				a.migrationProblem(entry.Path, err, destination)
				continue
			}
			if err = a.store.Save(key, *doc); err != nil {
				return err
			}
			index[entry.Path] = object{"signature": signature, "key": key, "fingerprint": fingerprint}
		}
	}
	return a.store.CommitStates(map[string]any{"photo-source-index.json": index, "organization.json": a.organization})
}

func (a *App) migratePrivateSource() error {
	path, _ := a.legacySettings["lastSourceImagePath.v1"].(string)
	identifier, _ := a.legacySettings["lastSourceImageIdentifier.v1"].(string)
	if path == "" || a.legacyPhotoDirectory == "" {
		return nil
	}
	// 僅接受 Swift 私有目錄內的快取及相符指紋。
	root := filepath.Dir(a.legacyPhotoDirectory)
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return err
	}
	root, _ = filepath.EvalSymlinks(root)
	rel, err := filepath.Rel(root, canonical)
	if err != nil || !filepath.IsLocal(rel) || !strings.HasPrefix(filepath.Base(rel), "last-opened-image.") {
		return errors.New("私有原圖不在舊版資料目錄")
	}
	fingerprint, err := storage.Fingerprint(context.Background(), canonical)
	if err != nil {
		return err
	}
	if identifier != "sha256:"+fingerprint {
		return errors.New("私有原圖與儲存的內容指紋不同")
	}
	var browser browserState
	_, err = a.store.LoadState("browser.json", &browser)
	if err != nil {
		return err
	}

	data, err := readBounded(canonical, 1024*1024*1024)
	if err != nil {
		return err
	}
	name := filepath.Join("private-source", fingerprint+strings.ToLower(filepath.Ext(canonical)))
	if err := a.store.PreserveFile(name, data); err != nil {
		return err
	}
	newPath := filepath.Join(a.store.Root(), name)
	original, _ := a.legacySettings["lastImageImportFilePath.v1"].(string)
	if original != "" {
		doc, err := a.legacyPhotoDocument(fingerprint, original)
		if err != nil {
			return err
		}
		if doc == nil {
			doc = &storage.Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{}, Manual: &storage.ManualAdjustments{HasCompleteHistory: true}}
		}
		doc.Source = &storage.PhotoSource{Path: newPath, Fingerprint: fingerprint, OriginalPath: original}
		key := storage.PhotoKey(newPath, fingerprint)
		if current, e := a.store.Load(key); e != nil {
			return e
		} else if current == nil {
			if e := a.store.Save(key, *doc); e != nil {
				return e
			}
		}
	}
	return a.store.SaveState("private-source.json", object{"path": newPath, "originalPath": original, "fingerprint": fingerprint})
}

func sha256Bytes(data []byte) string { hash := sha256.Sum256(data); return hex.EncodeToString(hash[:]) }

func (a *App) adoptRenderedMask(revision uint64, job contract.RenderJob) error {
	data, err := readBounded(*job.SubjectMaskOutputPath, 268435472)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	a.openMu.Lock()
	defer a.openMu.Unlock()
	a.mu.Lock()
	if revision != a.revision || a.sourceIdentity == nil || a.source != job.Input.Path {
		a.mu.Unlock()
		return nil
	}
	identity := clone(a.sourceIdentity)
	a.mu.Unlock()
	mask, err := a.store.ImportMask(data, identity.Fingerprint, repairDigest(job.Recipe.RepairPatches))
	if err != nil {
		return err
	}
	a.mu.Lock()
	if revision != a.revision {
		a.mu.Unlock()
		return nil
	}
	a.subjectMask = mask
	a.mu.Unlock()
	return a.persist()
}

// 書籤解析與人工重新定位都以明確的路徑對應為依據，不依內容猜測副本。
func (a *App) legacySourcePaths(path string) []string {
	result := []string{path}
	var aliases map[string]struct {
		From      string `json:"from"`
		To        string `json:"to"`
		Directory bool   `json:"directory"`
	}
	if _, err := a.store.LoadState("path-aliases.json", &aliases); err != nil {
		return result
	}
	for _, alias := range aliases {
		if filepath.Clean(alias.To) == filepath.Clean(path) {
			result = append(result, alias.From)
		} else if alias.Directory {
			if rel, err := filepath.Rel(alias.To, path); err == nil && filepath.IsLocal(rel) {
				result = append(result, filepath.Join(alias.From, rel))
			}
		}
	}
	return result
}
func (a *App) restoreRelocatedMetadata(oldPath, newPath string) {
	oldID, newID := photos.Identity(oldPath), photos.Identity(newPath)
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.organization.Photos == nil {
		a.organization.Photos = map[string]photoMetadata{}
	}
	if a.organization.Edited == nil {
		a.organization.Edited = map[string]bool{}
	}
	if _, exists := a.organization.Photos[newID]; !exists {
		if value, ok := a.organization.Photos[oldID]; ok {
			a.organization.Photos[newID] = value
		}
	}
	if _, exists := a.organization.Edited[newID]; !exists {
		if value, ok := a.organization.Edited[oldID]; ok {
			a.organization.Edited[newID] = value
		}
	}
}

// 私有快取只改變讀取位置，顯示及匯出名稱維持原本照片名稱。
func (a *App) logicalSourcePath() string {
	if a.sourceIdentity != nil && a.sourceIdentity.OriginalPath != "" {
		return a.sourceIdentity.OriginalPath
	}
	return a.source
}
