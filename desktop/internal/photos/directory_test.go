package photos

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestDirectoryOrderingAndBoundaries(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "繁體中文 目錄")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"photo10.JPG", "photo2.jpg", "camera.NEF", ".hidden.png", "readme.txt"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("測試"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.Mkdir(filepath.Join(directory, "subfolder.png"), 0700)
	_ = os.Symlink(filepath.Join(directory, "photo2.jpg"), filepath.Join(directory, "alias.jpg"))
	result, err := Scan(context.Background(), directory)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range result.Entries {
		names = append(names, entry.Name)
		if !entry.Unchanged() {
			t.Fatal("未修改來源被判為過期")
		}
	}
	if !reflect.DeepEqual(names, []string{"camera.NEF", "photo2.jpg", "photo10.JPG"}) {
		t.Fatalf("自然排序或檔案過濾錯誤：%v", names)
	}
	before := result.Entries[1]
	now := time.Now().Add(time.Second)
	if err := os.Chtimes(before.Path, now, now); err != nil {
		t.Fatal(err)
	}
	if before.Unchanged() {
		t.Fatal("修改後的來源仍使用舊縮圖")
	}
	after, err := Scan(context.Background(), directory)
	if err != nil {
		t.Fatal(err)
	}
	if after.ByID[before.ID].CacheKey == before.CacheKey {
		t.Fatal("修改來源未使縮圖快取失效")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Scan(ctx, directory); !errors.Is(err, context.Canceled) {
		t.Fatalf("未取消掃描：%v", err)
	}
	if _, err := Scan(context.Background(), before.Path); err == nil {
		t.Fatal("把檔案當成目錄")
	}
}
