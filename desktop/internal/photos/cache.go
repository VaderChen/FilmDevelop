package photos

import (
	"bytes"
	"image/jpeg"
	"io"
	"os"
	"path/filepath"
	"sort"
)

const MaxThumbnailBytes = 2 * 1024 * 1024

// 只驗證 JPEG 標頭及大小；Go 不解碼或重算照片像素。
func ValidThumbnail(data []byte) bool {
	if len(data) == 0 || len(data) > MaxThumbnailBytes {
		return false
	}
	info, err := jpeg.DecodeConfig(bytes.NewReader(data))
	return err == nil && info.Width > 0 && info.Height > 0 && info.Width <= 512 && info.Height <= 512
}

type Cache struct{ Directory string }

func (c Cache) Read(key string) []byte {
	file, err := os.Open(filepath.Join(c.Directory, key+".jpg"))
	if err != nil {
		return nil
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, MaxThumbnailBytes+1))
	if err != nil || !ValidThumbnail(data) {
		return nil
	}
	return data
}

func (c Cache) Write(key string, data []byte) {
	if !ValidThumbnail(data) || os.MkdirAll(c.Directory, 0700) != nil {
		return
	}
	file, err := os.CreateTemp(c.Directory, ".thumbnail-*")
	if err != nil {
		return
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	closeErr := file.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(file.Name(), filepath.Join(c.Directory, key+".jpg"))
	}
}

// 快取不可阻止瀏覽；只刪除本快取目錄內最舊的派生 JPEG。
func (c Cache) Prune() {
	entries, err := os.ReadDir(c.Directory)
	if err != nil {
		return
	}
	type item struct {
		name           string
		size, modified int64
	}
	var files []item
	var total int64
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".jpg" || len(entry.Name()) != 68 {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		files = append(files, item{entry.Name(), info.Size(), info.ModTime().UnixNano()})
		total += info.Size()
	}
	sort.Slice(files, func(i, j int) bool { return files[i].modified < files[j].modified })
	count := len(files)
	for _, file := range files {
		if total <= 256*1024*1024 && count <= 4096 {
			break
		}
		if os.Remove(filepath.Join(c.Directory, file.name)) == nil {
			total -= file.size
			count--
		}
	}
}
