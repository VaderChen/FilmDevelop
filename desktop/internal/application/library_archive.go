package application

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	pathpkg "path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type archivePhoto struct {
	Root     string           `json:"root"`
	Relative string           `json:"relative"`
	Document storage.Document `json:"document"`
	Metadata photoMetadata    `json:"metadata"`
	Edited   bool             `json:"edited"`
}
type libraryArchive struct {
	Format     string                     `json:"format"`
	Version    int                        `json:"version"`
	Roots      map[string]string          `json:"roots"`
	Photos     []archivePhoto             `json:"photos"`
	States     map[string]json.RawMessage `json:"states"`
	Unresolved int                        `json:"unresolved"`
}
type archiveImport struct {
	Archive      libraryArchive
	Assets       map[string][]byte
	Photos       map[string]storage.Document
	Organization organization
	Messages     []string
	Conflicts    int
}

var portableStates = []string{"preferences.json", "custom-films.json", "prompts.json", "decorations.json", "ui-preferences.json"}

func (a *App) writeLibraryArchive(path string) error {
	manifest := libraryArchive{Format: "FilmDevelop.library", Version: 1, Roots: map[string]string{}, States: map[string]json.RawMessage{}, Photos: []archivePhoto{}}
	files := map[string]string{}
	resolvedLegacy := map[string]bool{}
	entries, err := os.ReadDir(filepath.Join(a.store.Root(), "photos"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") || !entry.Type().IsRegular() {
			continue
		}
		key := strings.TrimSuffix(entry.Name(), ".json")
		doc, err := a.store.Load(key)
		if err != nil {
			return err
		}
		if doc.Source == nil {
			manifest.Unresolved++
			files["unresolved/"+entry.Name()] = filepath.Join(a.store.Root(), "photos", entry.Name())
			continue
		}
		resolvedLegacy[storage.PhotoKey(doc.Source.Path, "sha256:"+doc.Source.Fingerprint)+".json"] = true
		logical := doc.Source.Path
		if doc.Source.OriginalPath != "" {
			logical = doc.Source.OriginalPath
		}
		rootPath := filepath.Dir(logical)
		rootID := sourceHash(rootPath)[:16]
		manifest.Roots[rootID] = rootPath
		id := photos.Identity(doc.Source.Path)
		manifest.Photos = append(manifest.Photos, archivePhoto{rootID, filepath.Base(logical), *doc, a.organization.Photos[id], a.organization.Edited[id]})
		if doc.SubjectMask != nil {
			if err := a.store.ValidateMaskAsset(doc.SubjectMask); err != nil {
				return err
			}
			files["assets/"+doc.SubjectMask.SHA256+".mask.rgba"] = a.store.MaskPath(doc.SubjectMask)
		}
	}
	for _, name := range portableStates {
		var value json.RawMessage
		if found, err := a.store.LoadState(name, &value); err != nil {
			return err
		} else if found {
			// MCP 認證與本機路徑不跟著跨電腦設定包搬移。
			if name == "preferences.json" {
				var p object
				_ = json.Unmarshal(value, &p)
				delete(p, "mcpEnabled")
				delete(p, "defaultExportDirectory")
				value, _ = json.Marshal(p)
			}
			manifest.States[name] = value
		}
	}
	// 保留無法反推路徑的舊雜湊記錄，清楚列為待定位，不能假稱已全數配對。
	err = filepath.WalkDir(filepath.Join(a.store.Root(), "legacy"), func(path string, entry os.DirEntry, e error) error {
		if errors.Is(e, os.ErrNotExist) {
			return nil
		}
		if e != nil {
			return e
		}
		if entry.IsDir() || !entry.Type().IsRegular() {
			return nil
		}
		rel, _ := filepath.Rel(a.store.Root(), path)
		files[filepath.ToSlash(rel)] = path
		if strings.HasSuffix(entry.Name(), ".json") && len(entry.Name()) == 69 && !resolvedLegacy[entry.Name()] {
			manifest.Unresolved++
		}
		return nil
	})
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".library-*.zip")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	z := zip.NewWriter(f)
	add := func(name string, data []byte) error {
		w, e := z.Create(name)
		if e != nil {
			return e
		}
		_, e = w.Write(data)
		return e
	}
	data, _ := json.MarshalIndent(manifest, "", "  ")
	if err = add("manifest.json", data); err != nil {
		z.Close()
		f.Close()
		return err
	}
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		data, e := readBounded(files[name], 268435472)
		if e == nil {
			e = add(name, data)
		}
		if e != nil {
			z.Close()
			f.Close()
			return e
		}
	}
	if err = z.Close(); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

func readLibraryArchive(path string) (libraryArchive, map[string][]byte, error) {
	var manifest libraryArchive
	z, err := zip.OpenReader(path)
	if err != nil {
		return manifest, nil, err
	}
	defer z.Close()
	assets := map[string][]byte{}
	var total uint64
	if len(z.File) > 10000 {
		return manifest, nil, errors.New("資料包項目過多")
	}
	for _, f := range z.File {
		name := f.Name
		if pathpkg.Clean(name) != name || strings.ContainsAny(name, "\x00:\\") || !filepath.IsLocal(filepath.FromSlash(name)) || strings.HasPrefix(name, "/") || f.Mode()&os.ModeSymlink != 0 {
			return manifest, nil, errors.New("資料包路徑不符")
		}
		if name != "manifest.json" && !strings.HasPrefix(name, "assets/") && !strings.HasPrefix(name, "legacy/") && !strings.HasPrefix(name, "unresolved/") {
			return manifest, nil, errors.New("資料包有未知檔案")
		}
		if _, ok := assets[name]; ok {
			return manifest, nil, errors.New("資料包有重複路徑")
		}
		total += f.UncompressedSize64
		if total > 2*1024*1024*1024 || f.UncompressedSize64 > 268435472 {
			return manifest, nil, errors.New("資料包超過大小限制")
		}
		r, e := f.Open()
		if e != nil {
			return manifest, nil, e
		}
		data, e := io.ReadAll(io.LimitReader(r, 268435473))
		r.Close()
		if e != nil {
			return manifest, nil, e
		}
		if len(data) > 268435472 {
			return manifest, nil, errors.New("資料包檔案過大")
		}
		assets[name] = data
	}
	if json.Unmarshal(assets["manifest.json"], &manifest) != nil || manifest.Format != "FilmDevelop.library" || manifest.Version != 1 {
		return manifest, nil, errors.New("資料包格式或版本不符")
	}
	return manifest, assets, nil
}

func (a *App) planLibraryImport(ctx context.Context, path string, roots map[string]string) (*archiveImport, error) {
	manifest, assets, err := readLibraryArchive(path)
	if err != nil {
		return nil, err
	}
	if err := a.validateArchiveStates(manifest.States); err != nil {
		return nil, err
	}
	plan := &archiveImport{Archive: manifest, Assets: assets, Photos: map[string]storage.Document{}, Organization: sanitizeOrganization(a.organization)}
	mapped := map[string]bool{}
	for _, item := range manifest.Photos {
		root, ok := roots[item.Root]
		if !ok || root == "" {
			plan.Messages = append(plan.Messages, "尚未指定目錄："+manifest.Roots[item.Root])
			continue
		}
		if !filepath.IsLocal(filepath.FromSlash(item.Relative)) || strings.Contains(item.Relative, "\\") {
			return nil, errors.New("照片相對路徑不符")
		}
		target, err := photos.Canonical(filepath.Join(root, filepath.FromSlash(item.Relative)))
		if err != nil {
			plan.Messages = append(plan.Messages, "找不到照片："+item.Relative)
			continue
		}
		canonicalRoot, err := photos.Canonical(root)
		if err != nil {
			return nil, err
		}
		relative, err := filepath.Rel(canonicalRoot, target)
		if err != nil || !filepath.IsLocal(relative) {
			return nil, errors.New("重新定位的照片超出指定目錄")
		}
		doc := item.Document
		if doc.Version != 1 || doc.Source == nil || doc.Recipes == nil || doc.Selected == "" {
			return nil, errors.New("照片文件不完整")
		}
		fingerprint, err := storage.Fingerprint(ctx, target)
		if err != nil {
			return nil, err
		}
		if fingerprint != doc.Source.Fingerprint {
			plan.Messages = append(plan.Messages, "原圖內容不同："+item.Relative)
			continue
		}
		key := storage.PhotoKey(target, fingerprint)
		if mapped[key] {
			return nil, errors.New("兩筆舊照片對應到同一個新位置，請分開指定目錄")
		}
		mapped[key] = true
		existingTarget := false
		if current, err := a.store.Load(key); err != nil {
			return nil, err
		} else if current != nil {
			existingTarget = true
			plan.Conflicts++
		}
		for id, r := range doc.Recipes {
			if len(doc.SharedRepairPatches) > 0 {
				if string(r.RepairPatches) != "[]" {
					return nil, errors.New("共用修復紀錄衝突")
				}
				r.RepairPatches = doc.SharedRepairPatches
			}
			if id != r.Style {
				return nil, errors.New("照片配方識別不符")
			}
			normalized, err := a.services.NormalizeRecipe(r)
			if err != nil {
				return nil, err
			}
			doc.Recipes[id] = normalized
		}
		doc.SharedRepairPatches = nil
		if _, ok := a.defaults[doc.Selected]; !ok {
			return nil, errors.New("照片所選底片不存在")
		}
		if doc.CustomBase != nil {
			normalized, e := a.services.NormalizeRecipe(*doc.CustomBase)
			if e != nil {
				return nil, e
			}
			doc.CustomBase = &normalized
		}
		if mask := doc.SubjectMask; mask != nil {
			data, ok := assets["assets/"+mask.SHA256+".mask.rgba"]
			if !ok {
				return nil, errors.New("資料包缺少主體遮罩")
			}
			w, h, e := storage.ValidateMask(data)
			if e != nil {
				return nil, e
			}
			if sha256Bytes(data) != mask.SHA256 || w != mask.Width || h != mask.Height || mask.SourceFingerprint != fingerprint {
				return nil, errors.New("資料包主體遮罩完整性檢查失敗")
			}
		}
		doc.Source = &storage.PhotoSource{Path: target, Fingerprint: fingerprint}
		if !existingTarget {
			plan.Photos[key] = doc
		}
		id := photos.Identity(target)
		if item.Metadata.Rating < 0 || item.Metadata.Rating > 5 {
			return nil, errors.New("資料包分級不符")
		}
		for _, tag := range item.Metadata.Tags {
			if _, e := validName(tag, 40); e != nil {
				return nil, e
			}
			if !contains(plan.Organization.Tags, tag) {
				plan.Organization.Tags = append(plan.Organization.Tags, tag)
			}
		}
		if _, exists := plan.Organization.Photos[id]; !exists {
			plan.Organization.Photos[id] = item.Metadata
		}
		if _, exists := plan.Organization.Edited[id]; !exists {
			plan.Organization.Edited[id] = item.Edited
		}
	}
	return plan, nil
}

func (a *App) applyLibraryImport(plan *archiveImport) error {
	// 保留原始資料包內容，離線照片未定位不會被丟棄；不將其中檔案當成指令執行。
	for key, doc := range plan.Photos {
		if doc.Source == nil {
			return errors.New("照片來源資訊不完整")
		}
		hash, err := storage.Fingerprint(a.ctx, doc.Source.Path)
		if err != nil {
			return err
		}
		if hash != doc.Source.Fingerprint {
			return errors.New("照片在預覽後已變更，請重新匯入")
		}
		if current, err := a.store.Load(key); err != nil {
			return err
		} else if current != nil {
			return errors.New("預览後已有新的編輯紀錄，請重新匯入確認衝突")
		}
	}
	archiveID := sourceHash(plan.Archive)
	for name, data := range plan.Assets {
		if err := a.store.PreserveFile(filepath.Join("imports", archiveID, filepath.FromSlash(name)), data); err != nil {
			return err
		}
	}
	for key, doc := range plan.Photos {
		if doc.SubjectMask != nil {
			mask := doc.SubjectMask
			data := plan.Assets["assets/"+mask.SHA256+".mask.rgba"]
			if _, err := a.store.ImportMask(data, mask.SourceFingerprint, mask.RepairDigest); err != nil {
				return err
			}
		}
		if err := a.store.Save(key, doc); err != nil {
			return err
		}
	}
	for id, value := range a.organization.Photos {
		plan.Organization.Photos[id] = value
	}
	for id, value := range a.organization.Edited {
		plan.Organization.Edited[id] = value
	}
	if err := a.store.SaveState("organization.json", plan.Organization); err != nil {
		return err
	}
	a.organization = plan.Organization
	for name, raw := range plan.Archive.States {
		if !contains(portableStates, name) {
			return errors.New("資料包設定名稱不符")
		}
		if name == "custom-films.json" {
			continue
		} // 以相同逐筆驗證入口匯入，保留既有 ID。
		var values object
		if json.Unmarshal(raw, &values) != nil {
			return errors.New("資料包設定格式錯誤")
		}
		if name == "preferences.json" {
			delete(values, "mcpEnabled")
			delete(values, "defaultExportDirectory")
		}
		if name == "ui-preferences.json" {
			values = allowedUIPreferences(values)
		}
		if err := a.mergeLegacyState(name, values); err != nil {
			return err
		}
	}
	if raw, ok := plan.Archive.States["custom-films.json"]; ok {
		parent := filepath.Join(a.store.Root(), "imports", archiveID)
		if err := a.store.PreserveFile(filepath.Join("imports", archiveID, "CustomFilms.json"), raw); err != nil {
			return err
		}
		previous := a.legacyPhotoDirectory
		a.legacyPhotoDirectory = filepath.Join(parent, "PhotoEdits")
		err := a.loadUserLibrary()
		a.legacyPhotoDirectory = previous
		if err != nil {
			return err
		}
	}
	if err := a.loadPreferences(); err != nil {
		return err
	}
	if err := a.loadDecorations(); err != nil {
		return err
	}
	a.state()
	a.directoryState()
	return nil
}

func (a *App) exportLibraryArchive() error {
	if err := a.persist(); err != nil {
		return err
	}
	path, err := wruntime.SaveFileDialog(a.ctx, wruntime.SaveDialogOptions{Title: "匯出照片資料庫", DefaultFilename: "FilmDevelop-library.zip", Filters: []wruntime.FileFilter{{DisplayName: "照片資料庫", Pattern: "*.zip"}}})
	if err != nil || path == "" {
		return err
	}
	if err = a.writeLibraryArchive(path); err == nil {
		a.toast(errors.New("資料庫已匯出；原始照片請另行複製。"))
	}
	return err
}
func (a *App) importLibraryArchive() error {
	path, err := wruntime.OpenFileDialog(a.ctx, wruntime.OpenDialogOptions{Title: "選取照片資料庫", Filters: []wruntime.FileFilter{{DisplayName: "照片資料庫", Pattern: "*.zip"}}})
	if err != nil || path == "" {
		return err
	}
	manifest, _, err := readLibraryArchive(path)
	if err != nil {
		return err
	}
	roots := map[string]string{}
	ids := make([]string, 0, len(manifest.Roots))
	for id := range manifest.Roots {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		folder, e := wruntime.OpenDirectoryDialog(a.ctx, wruntime.OpenDialogOptions{Title: "指定照片新位置：" + manifest.Roots[id]})
		if e != nil {
			return e
		}
		if folder != "" {
			roots[id] = folder
		}
	}
	plan, err := a.planLibraryImport(a.ctx, path, roots)
	if err != nil {
		return err
	}
	detail := fmt.Sprintf("可移入 %d 張照片；保留新版衝突 %d 張；未定位 %d 筆。\n原始照片不會改寫。", len(plan.Photos), plan.Conflicts, len(plan.Messages)+manifest.Unresolved)
	if len(plan.Messages) > 0 {
		detail += "\n" + strings.Join(plan.Messages, "\n")
	}
	return a.showDialog("確認資料移轉", detail, "", []dialogChoice{{ID: "import", Label: "套用移轉"}}, func(string) error { return a.applyLibraryImport(plan) })
}
