package engine

import (
	"bytes"
	"context"
	"github.com/VaderChen/FilmDevelop/internal/contract"
	"os"
	"path/filepath"
	"testing"
)

func TestExifFailureDoesNotPublish(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source.jpg")
	data, e := os.ReadFile("../exifmeta/testdata/source.jpg")
	if e != nil {
		t.Fatal(e)
	}
	os.WriteFile(source, data, 0600)
	target := filepath.Join(filepath.Dir(source), "result.png")
	enabled := true
	job := contract.RenderJob{Input: contract.ImageInput{Path: source}, Output: contract.ImageOutput{Path: target, Format: "png", WriteExif: &enabled}}
	// 測試程序故意回傳不含尺寸的無效成品；EXIF 失敗不可發布半成品。
	if _, e := helper("ok").Render(context.Background(), job, nil); e == nil {
		t.Fatal("無效 EXIF 成品被發布")
	}
	if _, e := os.Stat(target); !os.IsNotExist(e) {
		t.Fatal("失敗留下目的檔案")
	}
	after, _ := os.ReadFile(source)
	if !bytes.Equal(after, data) {
		t.Fatal("原圖被更動")
	}
	pending, _ := filepath.Glob(filepath.Join(filepath.Dir(source), ".filmdevelop-work-*"))
	if len(pending) != 0 {
		t.Fatal("EXIF 失敗未清理暫存")
	}
}
