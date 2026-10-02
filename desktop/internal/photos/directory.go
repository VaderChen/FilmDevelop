// Package photos 管理跨平台照片目錄與縮圖快取；像素解碼由平台引擎提供。
package photos

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/text/collate"
	"golang.org/x/text/language"
)

type Entry struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	ModifiedAt float64 `json:"modifiedAt"`
	Path       string  `json:"-"`
	CacheKey   string  `json:"-"`
	Size       int64   `json:"-"`
	ModifiedNS int64   `json:"-"`
}

type Directory struct {
	Path    string
	Entries []Entry
	ByID    map[string]Entry
}

func Identity(path string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(path)))
	return hex.EncodeToString(sum[:])
}

func Canonical(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(absolute)
}

var extensions = func() map[string]bool {
	values := map[string]bool{}
	for _, ext := range strings.Fields("jpg jpeg jpe png tif tiff webp heic heif avif bmp gif jp2 j2k pict pic 3fr arw cr2 cr3 crw dng erf fff iiq kdc mef mos mrw nef nrw orf pef raf raw rw2 rwl srw sr2 srf x3f") {
		values["."+ext] = true
	}
	return values
}()

func Scan(ctx context.Context, path string) (Directory, error) {
	path, err := Canonical(path)
	if err != nil {
		return Directory{}, err
	}
	file, err := os.Open(path)
	if err != nil {
		return Directory{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Directory{}, err
	}
	if !info.IsDir() {
		return Directory{}, errors.New("選取的路徑不是資料夾")
	}
	result := Directory{Path: path, Entries: []Entry{}, ByID: map[string]Entry{}}
	for {
		if err := ctx.Err(); err != nil {
			return Directory{}, err
		}
		batch, readErr := file.ReadDir(256)
		for _, candidate := range batch {
			if err := ctx.Err(); err != nil {
				return Directory{}, err
			}
			if strings.HasPrefix(candidate.Name(), ".") || !extensions[strings.ToLower(filepath.Ext(candidate.Name()))] || candidate.Type()&os.ModeSymlink != 0 {
				continue
			}
			info, err := candidate.Info()
			if err != nil || !info.Mode().IsRegular() || hidden(info) {
				continue
			}
			entry := Entry{Name: candidate.Name(), Path: filepath.Join(path, candidate.Name()), Size: info.Size(), ModifiedNS: info.ModTime().UnixNano(), ModifiedAt: float64(info.ModTime().UnixMilli()) / 1000}
			entry.ID = Identity(entry.Path)
			entry.CacheKey = Identity(fmt.Sprintf("thumbnail-v2-content-256\n%s\n%d\n%d", entry.Path, entry.Size, entry.ModifiedNS))
			result.Entries = append(result.Entries, entry)
			result.ByID[entry.ID] = entry
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return Directory{}, readErr
		}
	}
	order := collate.New(language.Und, collate.Numeric, collate.IgnoreCase)
	sort.SliceStable(result.Entries, func(i, j int) bool {
		a, b := result.Entries[i], result.Entries[j]
		if compared := order.CompareString(a.Name, b.Name); compared != 0 {
			return compared < 0
		}
		return a.Path < b.Path
	})
	return result, nil
}

func (e Entry) Unchanged() bool {
	info, err := os.Lstat(e.Path)
	return err == nil && info.Mode().IsRegular() && info.Size() == e.Size && info.ModTime().UnixNano() == e.ModifiedNS
}
