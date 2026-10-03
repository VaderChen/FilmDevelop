package photos

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestImportEntrypointsShareFormats(t *testing.T) {
	patterns := strings.Split(FileDialogPattern(), ";")
	if len(patterns) != len(extensions) {
		t.Fatal("選檔與列表格式數不同")
	}
	for ext := range extensions {
		path := "照片" + strings.ToUpper(ext)
		if !Supported(path) {
			t.Fatal("拖放漏掉格式", ext)
		}
		found := false
		for _, pattern := range patterns {
			matched, _ := filepath.Match(pattern, strings.ToLower(path))
			found = found || matched
		}
		if !found {
			t.Fatal("選檔漏掉格式", ext)
		}
	}
	if Supported("notes.txt") {
		t.Fatal("接受非影像檔案")
	}
}
