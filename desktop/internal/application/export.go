package application

import (
	"encoding/json"
	"errors"
	"github.com/VaderChen/FilmDevelop/internal/contract"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"path/filepath"
	"strings"
)

type ExportSettings struct {
	MaxPixel        int    `json:"maxPixel"`
	Format          string `json:"format"`
	ColorSpace      string `json:"colorSpace"`
	JPEGQuality     int    `json:"jpegQuality"`
	WebPQuality     int    `json:"webpQuality"`
	WebPLossless    bool   `json:"webpLossless"`
	PNGDepth        int    `json:"pngDepth"`
	TIFFDepth       int    `json:"tiffDepth"`
	TIFFCompression int    `json:"tiffCompression"`
	WriteExif       bool   `json:"writeExif"`
}

// 與 Swift 匯出一致：來源資料夾名稱＋空格＋去除副檔名的來源檔名。
// 單張與批次共用命名，輸出目錄不影響名稱。
func exportName(source string) string {
	if source == "" {
		return "PhotoStyle"
	}
	name := filepath.Base(source)
	if ext := filepath.Ext(name); ext != name {
		name = strings.TrimSuffix(name, ext)
	}
	directory := filepath.Dir(source)
	if directory == "." || filepath.Dir(directory) == directory {
		return name
	}
	return filepath.Base(directory) + " " + name
}

func (s ExportSettings) fileExtension() string {
	switch s.Format {
	case "jpeg":
		return "jpg"
	case "tiff":
		return "tif"
	default:
		return s.Format
	}
}

func (s ExportSettings) saveDialogOptions(source, directory string) wruntime.SaveDialogOptions {
	ext := s.fileExtension()
	pattern := "*." + ext
	if ext != s.Format {
		pattern += ";*." + s.Format
	}
	return wruntime.SaveDialogOptions{Title: "匯出照片", DefaultDirectory: directory,
		DefaultFilename: exportName(source) + "." + ext,
		Filters:         []wruntime.FileFilter{{DisplayName: s.Format, Pattern: pattern}}}
}

func (s ExportSettings) matchesExtension(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return ext == "."+s.Format || (s.Format == "jpeg" && ext == ".jpg") || (s.Format == "tiff" && ext == ".tif")
}

func defaultExportSettings() ExportSettings {
	return ExportSettings{Format: "png", ColorSpace: "sRGB", JPEGQuality: 95, WebPQuality: 95, PNGDepth: 8, TIFFDepth: 16, TIFFCompression: 1, WriteExif: true}
}
func (s *ExportSettings) update(key string, value any) error {
	data, _ := json.Marshal(s)
	var fields object
	_ = json.Unmarshal(data, &fields)
	if _, ok := fields[key]; !ok {
		return errors.New("未知的匯出設定")
	}
	fields[key] = value
	data, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	var next ExportSettings
	if err := json.Unmarshal(data, &next); err != nil {
		return errors.New("匯出設定型別錯誤")
	}
	validFormat := next.Format == "png" || next.Format == "jpeg" || next.Format == "webp" || next.Format == "tiff"
	validColor := next.ColorSpace == "sRGB" || next.ColorSpace == "displayP3" || next.ColorSpace == "adobeRGB"
	if !validFormat || !validColor || next.MaxPixel < 0 || next.MaxPixel > 65536 || next.JPEGQuality < 1 || next.JPEGQuality > 100 || next.WebPQuality < 1 || next.WebPQuality > 100 || (next.PNGDepth != 8 && next.PNGDepth != 16) || (next.TIFFDepth != 8 && next.TIFFDepth != 16) || (next.TIFFCompression != 1 && next.TIFFCompression != 5) {
		return errors.New("匯出設定超出支援範圍")
	}
	*s = next
	return nil
}
func (s ExportSettings) output(path string) contract.ImageOutput {
	depth, quality := 8, float64(s.JPEGQuality)/100
	switch s.Format {
	case "png":
		depth = s.PNGDepth
	case "tiff":
		depth = s.TIFFDepth
	case "webp":
		quality = float64(s.WebPQuality) / 100
	}
	return contract.ImageOutput{Path: path, Format: s.Format, BitDepth: depth, ColorSpace: s.ColorSpace, Quality: quality, MaxPixel: s.MaxPixel, WebPLossless: s.WebPLossless, TiffCompression: s.TIFFCompression, WriteExif: &s.WriteExif}
}
