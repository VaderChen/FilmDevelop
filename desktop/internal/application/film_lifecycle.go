package application

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/rivo/uniseg"
)

// 呼叫端持有 App.mu。失效的底片身分不可覆蓋照片已保存的調整參數。
func (a *App) detachUnavailableFilm() {
	film, exists := a.findFilm(a.selectedCustom)
	if !exists || film.BaseStyle != a.selected {
		a.selectedCustom, a.customBase = "", nil
	}
}

func (a *App) filmIDByName(name string) string {
	key := filmNameKey(strings.TrimSpace(name))
	for _, film := range a.customFilms {
		if filmNameKey(film.Name) == key {
			return film.ID
		}
	}
	return ""
}

func (a *App) duplicateFilm(film CustomFilm) error {
	a.mu.Lock()
	var name string
	for number := 1; ; number++ {
		suffix := " 副本"
		if number > 1 {
			suffix += fmt.Sprintf(" (%d)", number)
		}
		graphemes := uniseg.NewGraphemes(film.Name)
		var prefix strings.Builder
		for remaining := 80 - uniseg.GraphemeClusterCount(suffix); remaining > 0 && graphemes.Next(); remaining-- {
			prefix.WriteString(graphemes.Str())
		}
		name = prefix.String() + suffix
		if a.filmIDByName(name) == "" {
			break
		}
	}
	a.mu.Unlock()
	if err := a.saveFilm(name, filmRecipe(film), ""); err != nil {
		return err
	}
	a.mu.Lock()
	id := a.filmIDByName(name)
	a.mu.Unlock()
	if err := a.selectStyle(id); err != nil {
		return err
	}
	if err := a.persist(); err != nil {
		return err
	}
	a.preview()
	return nil
}

// 僅在系統儲存對話框已確認後使用；完成寫入前保留原檔，拒絕符號連結與競爭修改。
func writeConfirmedFile(path string, data []byte) error {
	old, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return writeExclusive(path, data)
	}
	if err != nil {
		return err
	}
	if !old.Mode().IsRegular() {
		return errors.New("輸出不是一般檔案")
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".filmdevelop-file-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	current, err := os.Lstat(path)
	if err != nil || !os.SameFile(old, current) || old.Size() != current.Size() || !old.ModTime().Equal(current.ModTime()) {
		return errors.New("目的檔案已被其他操作修改")
	}
	return os.Rename(f.Name(), path)
}
