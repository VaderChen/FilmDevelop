// Package photos 管理跨平台照片目錄與縮圖快取；像素解碼由平台引擎提供。
package photos

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
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
	for _, ext := range strings.Fields("jpg jpeg jpe png tif tiff webp heic heif avif bmp gif jp2 j2k pict pic 3fr arw cr2 cr3 crw dng erf fff gpr iiq kdc mef mos mrw nef nrw orf pef raf raw rw2 rwl srw sr2 srf x3f") {
		values["."+ext] = true
	}
	return values
}()

// 選檔、拖放與列表共用格式清單，避免不同入口漏掉相同檔案。
func Supported(path string) bool { return extensions[strings.ToLower(filepath.Ext(path))] }
func FileDialogPattern() string {
	patterns := make([]string, 0, len(extensions))
	for ext := range extensions {
		patterns = append(patterns, "*"+ext)
	}
	sort.Strings(patterns)
	return strings.Join(patterns, ";")
}

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
	result := Directory{Path: path, Entries: []Entry{}}
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
			entry.CacheKey = thumbnailIdentity(entry)
			result.Entries = append(result.Entries, entry)
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return Directory{}, readErr
		}
	}
	result.ByID = make(map[string]Entry, len(result.Entries))
	for _, entry := range result.Entries {
		result.ByID[entry.ID] = entry
	}
	if len(result.Entries) < 2 {
		return result, nil
	}
	order := collate.New(language.Und, collate.Numeric, collate.IgnoreCase)
	var buffer collate.Buffer
	keys := make([]string, len(result.Entries))
	for i, entry := range result.Entries {
		keys[i] = string(order.KeyFromString(&buffer, entry.Name))
		buffer.Reset()
	}
	// 每個名稱只建立一次 Unicode／數字排序鍵；同名時仍依路徑穩定排序。
	sort.Stable(directoryOrder{entries: result.Entries, keys: keys})
	return result, nil
}

func thumbnailIdentity(entry Entry) string {
	// 保持既有鍵值的位元組格式；整數直接寫入摘要輸入，省去格式化的中間物件。
	const prefix = "thumbnail-v2-content-256\n"
	data := make([]byte, 0, len(prefix)+len(entry.Path)+2+2*20)
	data = append(data, prefix...)
	data = append(data, entry.Path...)
	data = append(data, '\n')
	data = strconv.AppendInt(data, entry.Size, 10)
	data = append(data, '\n')
	data = strconv.AppendInt(data, entry.ModifiedNS, 10)
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

type directoryOrder struct {
	entries []Entry
	keys    []string
}

func (s directoryOrder) Len() int { return len(s.entries) }
func (s directoryOrder) Less(i, j int) bool {
	if s.keys[i] != s.keys[j] {
		return s.keys[i] < s.keys[j]
	}
	return s.entries[i].Path < s.entries[j].Path
}
func (s directoryOrder) Swap(i, j int) {
	s.entries[i], s.entries[j] = s.entries[j], s.entries[i]
	s.keys[i], s.keys[j] = s.keys[j], s.keys[i]
}

func (e Entry) Unchanged() bool {
	info, err := os.Lstat(e.Path)
	return err == nil && info.Mode().IsRegular() && info.Size() == e.Size && info.ModTime().UnixNano() == e.ModifiedNS
}
