package updater

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMinimumMacOS(t *testing.T) {
	for _, c := range []struct {
		current, minimum string
		want             bool
	}{
		{"14.0", "14.0.0", true}, {"14.7.2", "14.0", true},
		{"26.0", "14.0", true}, {"13.7", "14.0", false},
		{"14.0.1", "14.0.2", false}, {"14.0", "invalid", false},
	} {
		if got := supportsOS(c.current, c.minimum); got != c.want {
			t.Fatalf("macOS %s / %s = %v", c.current, c.minimum, got)
		}
	}
}

// 使用實際封裝的 DMG 驗證掛載、簽章與暫存；不替換目前 App。
func TestPackagedMacUpdate(t *testing.T) {
	target, image := os.Getenv("FILMDEVELOP_UPDATE_SMOKE_APP"), os.Getenv("FILMDEVELOP_UPDATE_SMOKE_DMG")
	if target == "" || image == "" {
		t.Skip("未指定實際 App 與 DMG")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	m, err := metadata(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	v := Version{Version: m["CFBundleShortVersionString"].(string), Build: m["CFBundleVersion"].(string)}
	if err = ValidateBundle(ctx, target, m["CFBundleIdentifier"].(string), Version{Version: v.Version, Build: "invalid"}); err == nil {
		t.Fatal("錯誤版本不應通過驗證")
	}
	p, err := prepareBundle(ctx, target, image, v)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Discard()
	if p.Target != target || filepath.Dir(p.Staged) != filepath.Dir(target) || p.Staged == target {
		t.Fatal("更新暫存應與目標位於相同磁碟且隔離")
	}
	data, err := os.ReadFile(filepath.Join(p.Work, "receipt.json"))
	if err != nil {
		t.Fatal(err)
	}
	var receipt map[string]string
	if err = json.Unmarshal(data, &receipt); err != nil || receipt["target"] != target || receipt["tag"] != v.Tag() {
		t.Fatal("更新收據不符", err)
	}
	if _, err = os.Stat(filepath.Join(p.Work, "install.sh")); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(p.Backup); !os.IsNotExist(err) {
		t.Fatal("準備更新不得移動原始 App")
	}
	p.Discard()
	if _, err = os.Stat(p.Staged); !os.IsNotExist(err) {
		t.Fatal("取消更新未清理暫存")
	}
	if err = ValidateBundle(ctx, target, m["CFBundleIdentifier"].(string), v); err != nil {
		t.Fatal("原始 App 受到影響", err)
	}
}
