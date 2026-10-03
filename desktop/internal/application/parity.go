package application

import (
	"errors"
	"math"
	"os"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

func requiresSubject(recipe contract.Recipe) bool {
	fields := recipeFields(recipe)
	for _, key := range []string{"backgroundBlur", "skinWarmth", "skinWhitening", "skinSmoothing"} {
		if value, _ := fields[key].(float64); math.Abs(value) > .001 {
			return true
		}
	}
	return false
}

func (a *App) validSubjectMask(mask *storage.SubjectMask, source *storage.PhotoSource, recipe contract.Recipe) bool {
	return mask != nil && source != nil && mask.SourceFingerprint == source.Fingerprint &&
		mask.RepairDigest == repairDigest(recipe.RepairPatches) &&
		(mask.LensCorrection == nil && a.preferences.LensCorrection || mask.LensCorrection != nil && *mask.LensCorrection == a.preferences.LensCorrection)
}

func (a *App) openDroppedPhotos(paths []string) error {
	if len(paths) != 1 || !photos.Supported(paths[0]) {
		return errors.New("請拖入一張可讀取的照片或 RAW 檔案")
	}
	path, err := photos.Canonical(paths[0])
	if err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("請拖入照片檔案")
	}
	// 沿用原生開檔握手，先提交前端尚未送出的滑桿及裁切。
	a.OpenFileFromOS(path)
	return nil
}
