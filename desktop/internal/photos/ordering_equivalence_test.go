package photos

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"

	"golang.org/x/text/collate"
	"golang.org/x/text/language"
)

func TestDirectoryOrderingMatchesOriginal(t *testing.T) {
	folder := t.TempDir()
	names := []string{"圖1", "圖10", "圖2", "圖01", "École", "e\u0301cole", "ECOLE", "相簿甲", "相簿乙", "IMG_0002", "img_10", "Å", "A", "照片１２", "照片2", "사진", "写真", "😀_1", "😀_10", "1.2", "1.10"}
	for i, name := range names {
		if err := os.WriteFile(filepath.Join(folder, fmt.Sprintf("%s-%d.JPG", name, i)), []byte{1}, 0600); err != nil {
			t.Fatal(err)
		}
	}
	directory, err := Scan(context.Background(), folder)
	if err != nil {
		t.Fatal(err)
	}
	expected := append([]Entry{}, directory.Entries...)
	// 使用最佳化前的比較規則，含 Unicode 正規化、數字、不區分大小寫及路徑決勝。
	order := collate.New(language.Und, collate.Numeric, collate.IgnoreCase)
	sort.SliceStable(expected, func(i, j int) bool {
		if compared := order.CompareString(expected[i].Name, expected[j].Name); compared != 0 {
			return compared < 0
		}
		return expected[i].Path < expected[j].Path
	})
	if !reflect.DeepEqual(directory.Entries, expected) {
		t.Fatal("照片自然排序與既有規則不符")
	}
	for _, entry := range expected {
		if directory.ByID[entry.ID] != entry {
			t.Fatal("排序改變照片識別或中繼資料")
		}
		if entry.CacheKey != Identity(fmt.Sprintf("thumbnail-v2-content-256\n%s\n%d\n%d", entry.Path, entry.Size, entry.ModifiedNS)) {
			t.Fatal("縮圖快取識別與既有格式不符")
		}
	}
}
