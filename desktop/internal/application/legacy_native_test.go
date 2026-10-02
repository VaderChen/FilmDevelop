package application

import (
	"context"
	"os"
	"runtime"
	"testing"
	"time"
)

// 唯讀既有 Swift 偏好；全部遷移結果寫入測試目錄，不更動使用者資料。
func TestLegacyNativePreferencesMigration(t *testing.T) {
	binary := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_ENGINE")
	if binary == "" || runtime.GOOS != "darwin" {
		t.Skip("需明確指定 macOS 原生引擎")
	}
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	a, err := New(binary)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	a.ctx = ctx
	a.emit = func(string, any) {}
	if err = a.loadCatalog(); err != nil {
		t.Fatal(err)
	}
	if err = a.loadUserLibrary(); err != nil {
		t.Fatal(err)
	}
	// Store 已綁定測試目錄，此處只開啟讀取 macOS 舊設定的分支。
	t.Setenv("FILMDEVELOP_DATA_DIR", "")
	if err = a.migrateLegacySettings(); err != nil {
		t.Fatal(err)
	}
	if err = a.setPreference("setLanguage", object{"preference": "korean"}); err != nil {
		t.Fatal(err)
	}
	if err = a.migrateLegacySettings(); err != nil {
		t.Fatal(err)
	}
	if a.preferences.Language != "korean" {
		t.Fatal("重複遷移覆蓋了 Go 設定")
	}
	t.Log("既有 Swift 偏好可遷移，且保留已保存的 Go 偏好")
}
