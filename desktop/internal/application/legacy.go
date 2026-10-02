package application

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

// 舊檔只讀。新宿主首次保存時寫入自己的資料目錄，保留原始遷移來源。
func (a *App) legacyPhotoDocument(fingerprint, path string) (*storage.Document, error) {
	if a.legacyPhotoDirectory == "" {
		return nil, nil
	}
	// Swift 的 sourceImageIdentifier 是「sha256:」加上完整檔案雜湊。
	sourcePath := path
	key := storage.PhotoKey(path, "sha256:"+fingerprint)
	for _, candidate := range a.legacySourcePaths(path) {
		candidateKey := storage.PhotoKey(candidate, "sha256:"+fingerprint)
		if _, e := os.Stat(filepath.Join(a.legacyPhotoDirectory, candidateKey+".json")); e == nil {
			key = candidateKey
			sourcePath = candidate
			break
		}
	}
	editedPhotos, err := a.legacyEditedPhotos()
	if err != nil {
		return nil, err
	}
	canonical, err := photos.Canonical(sourcePath)
	if err != nil {
		// 私有原圖回復時原路徑可能離線，仍可用已核對的內容指紋讀舊紀錄。
		canonical, err = filepath.Abs(sourcePath)
		if err != nil {
			return nil, err
		}
		if parent, e := filepath.EvalSymlinks(filepath.Dir(canonical)); e == nil {
			canonical = filepath.Join(parent, filepath.Base(canonical))
		}
	}
	// 以來源的標記判斷舊版重設；Go 的標記可能已被先前的空白紀錄清除。
	edited, recorded := editedPhotos[photos.Identity(canonical)]
	if sourcePath != path {
		a.restoreRelocatedMetadata(sourcePath, path)
	}
	if recorded && !edited {
		return nil, nil
	}
	data, err := readBounded(filepath.Join(a.legacyPhotoDirectory, key+".json"), contract.MaxMessageBytes)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var saved struct {
		Version     int                        `json:"version"`
		Selected    string                     `json:"selectedStyle"`
		CustomID    string                     `json:"customFilmID"`
		CustomBase  json.RawMessage            `json:"customFilmBaseAdjustment"`
		Adjustments map[string]json.RawMessage `json:"adjustments"`
		Patches     json.RawMessage            `json:"repairPatches"`
		Manual      json.RawMessage            `json:"manualAdjustments"`
	}
	if err = json.Unmarshal(data, &saved); err != nil {
		return nil, err
	}
	if saved.Version != 1 {
		return nil, errors.New("舊照片調整版本不符")
	}
	if len(saved.Patches) == 0 || string(saved.Patches) == "null" {
		saved.Patches = json.RawMessage(`[]`)
	}
	doc := &storage.Document{Version: 1, Selected: saved.Selected, CustomID: saved.CustomID, Recipes: map[string]contract.Recipe{}}
	if len(saved.Manual) > 0 && string(saved.Manual) != "null" {
		if err = json.Unmarshal(saved.Manual, &doc.Manual); err != nil {
			return nil, err
		}
	}
	for id, adjustment := range saved.Adjustments {
		r, e := a.services.NormalizeRecipe(contract.Recipe{Version: 1, Style: id, Adjustment: adjustment, RepairPatches: saved.Patches})
		if e != nil {
			return nil, e
		}
		doc.Recipes[id] = r
	}
	if _, ok := doc.Recipes[doc.Selected]; !ok {
		r, ok := a.defaults[doc.Selected]
		if !ok {
			return nil, errors.New("舊照片底片不存在")
		}
		r.RepairPatches = saved.Patches
		doc.Recipes[doc.Selected] = r
	}
	if len(saved.CustomBase) > 0 && string(saved.CustomBase) != "null" {
		r, e := a.services.NormalizeRecipe(contract.Recipe{Version: 1, Style: saved.Selected, Adjustment: saved.CustomBase, RepairPatches: json.RawMessage(`[]`)})
		if e != nil {
			return nil, e
		}
		doc.CustomBase = &r
	}
	if !recorded && !a.legacyDocumentHasEdits(doc) {
		return nil, nil
	}
	maskPath := filepath.Join(a.legacyPhotoDirectory, key+".mask.rgba")
	if data, e := readBounded(maskPath, 268435472); e == nil {
		mask, e := a.store.ImportMask(data, fingerprint, repairDigest(saved.Patches))
		if e != nil {
			a.migrationProblem(maskPath, e, maskPath)
		} else {
			doc.SubjectMask = mask
		}
	} else if !errors.Is(e, os.ErrNotExist) {
		a.migrationProblem(maskPath, e, maskPath)
	}
	doc.Source = &storage.PhotoSource{Path: path, Fingerprint: fingerprint}
	return doc, nil
}

// 舊 Go 開圖失敗會保存「原片、無參數、歷史不完整」的空白紀錄。
// 僅這種紀錄可回退讀取 Swift；有調整內容或明確重設（完整歷史）一律保留。
func legacyPhotoPlaceholder(doc *storage.Document) bool {
	return doc.Selected == "original" && len(doc.Recipes) == 0 && doc.CustomID == "" && doc.CustomBase == nil &&
		len(doc.SharedRepairPatches) == 0 && (doc.Manual == nil || (!doc.Manual.HasCompleteHistory && len(doc.Manual.PrintControls) == 0))
}

func (a *App) legacyEditedPhotos() (map[string]bool, error) {
	result := map[string]bool{}
	if a.legacyPhotoDirectory == "" {
		return result, nil
	}
	data, err := readBounded(filepath.Join(a.legacyPhotoDirectory, "edited-photos.json"), 16*1024*1024)
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return nil, err
	}
	if err = json.Unmarshal(data, &result); err != nil {
		var keys []string
		if err = json.Unmarshal(data, &keys); err != nil {
			return nil, err
		}
		result = map[string]bool{}
		for _, key := range keys {
			result[key] = true
		}
	}
	return result, nil
}

// 與 Swift shouldRestoreEdits 相同：沒有標記索引時，不能將僅瀏覽產生的預設紀錄當成編輯。
func (a *App) legacyDocumentHasEdits(doc *storage.Document) bool {
	if doc.CustomID != "" || (doc.Manual != nil && len(doc.Manual.PrintControls) > 0) {
		return true
	}
	recipe := doc.Recipes[doc.Selected]
	var patches []json.RawMessage
	if json.Unmarshal(recipe.RepairPatches, &patches) != nil || len(patches) > 0 {
		return true
	}
	baseline, err := a.services.NormalizeRecipe(a.defaults[doc.Selected])
	if err != nil {
		return true
	}
	actual, defaults := recipeFields(recipe), recipeFields(baseline)
	if reflect.DeepEqual(actual, defaults) {
		return false
	}
	defaults["filmEffects"].(object)["scanner_profile"] = "off"
	return !reflect.DeepEqual(actual, defaults)
}

func (a *App) migrateLegacySettings() error {
	a.legacySettings = object{}
	if runtime.GOOS != "darwin" || os.Getenv("FILMDEVELOP_DATA_DIR") != "" {
		return nil
	}
	raw, err := a.services.Native(a.ctx, "legacySettings", object{}, nil)
	if err != nil {
		return err
	}
	if err = json.Unmarshal(raw, &a.legacySettings); err != nil {
		return err
	}
	return a.migrateLegacyValues()
}
