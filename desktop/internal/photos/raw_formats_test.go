package photos

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestRAWImportIncludesSupplementalFormats(t *testing.T) {
	directory := t.TempDir()
	for _, name := range []string{"nikon.NEF", "action.GPR", "photo.DNG", "notes.txt"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("僅測目錄清單，解碼另用真實樣本驗證"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	result, err := Scan(context.Background(), directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Entries) != 3 {
		t.Fatal("RAW 格式未完整出現在照片清單", result)
	}
}
