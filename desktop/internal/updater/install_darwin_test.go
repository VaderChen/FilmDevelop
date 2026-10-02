package updater

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	installed := v
	if tag := os.Getenv("FILMDEVELOP_UPDATE_SMOKE_TAG"); tag != "" {
		v, err = Parse(tag)
		if err != nil {
			t.Fatal(err)
		}
	}
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
	if err = ValidateBundle(ctx, target, m["CFBundleIdentifier"].(string), installed); err != nil {
		t.Fatal("原始 App 受到影響", err)
	}
}

func TestIdentityMigrationIsOneWay(t *testing.T) {
	for _, c := range []struct {
		source, destination string
		migration, allowed  bool
	}{
		{LegacyMacBundleIdentifier, MacBundleIdentifier, true, true},
		{MacBundleIdentifier, LegacyMacBundleIdentifier, true, false},
		{LegacyMacBundleIdentifier, MacBundleIdentifier, false, false},
		{"other.app", MacBundleIdentifier, true, false},
		{LegacyMacBundleIdentifier, "other.app", true, false},
		{MacBundleIdentifier, MacBundleIdentifier, false, true},
		{LegacyMacBundleIdentifier, LegacyMacBundleIdentifier, false, true},
		{"other.app", "other.app", false, false},
	} {
		if got := replacementIdentityAllowed(c.source, c.destination, c.migration); got != c.allowed {
			t.Fatalf("%s → %s（migration=%v）= %v", c.source, c.destination, c.migration, got)
		}
	}
}

// 實際正式簽章的過渡 App：驗證同磁碟暫存、單向識別、取消及重複呼叫。
func TestPackagedIdentityMigration(t *testing.T) {
	target := os.Getenv("FILMDEVELOP_MIGRATION_SMOKE_APP")
	if target == "" {
		t.Skip("未指定過渡 App")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	p, err := prepareIdentityMigration(ctx, target)
	if err != nil || p == nil {
		t.Fatalf("移轉準備失敗：%v", err)
	}
	defer p.Discard()
	if err = ValidateBundle(ctx, p.Staged, MacBundleIdentifier, p.Version); err != nil {
		t.Fatal(err)
	}
	if next, e := prepareIdentityMigration(ctx, p.Staged); e != nil || next != nil {
		t.Fatal("標準安裝不得再次移轉", e)
	}
	if err = ValidateBundle(ctx, target, LegacyMacBundleIdentifier, p.Version); err != nil {
		t.Fatal("準備移轉修改了原本 App", err)
	}
	data, err := os.ReadFile(filepath.Join(p.Work, "receipt.json"))
	var receipt map[string]string
	if err != nil || json.Unmarshal(data, &receipt) != nil || receipt["identifier"] != MacBundleIdentifier {
		t.Fatal("移轉收據未指定正式身分")
	}
	p.Discard()
	if _, err = os.Stat(p.Staged); !os.IsNotExist(err) {
		t.Fatal("取消移轉未清理暫存")
	}
	// 過渡來源改為 ad-hoc 後即使封裝結構仍有效，也不能跨識別安裝。
	unsigned := filepath.Join(t.TempDir(), "Unsigned.app")
	if _, err = run(ctx, "/usr/bin/ditto", target, unsigned); err != nil {
		t.Fatal(err)
	}
	if _, err = run(ctx, "/usr/bin/codesign", "--force", "--sign", "-", unsigned); err != nil {
		t.Fatal(err)
	}
	if bad, e := prepareIdentityMigration(ctx, unsigned); e == nil || bad != nil {
		if bad != nil {
			bad.Discard()
		}
		t.Fatal("未正式簽章的來源不應允許識別移轉")
	}
	// 內含 App 被改動時，不能確認舊更新收據或移動原本安裝。
	tampered := filepath.Join(t.TempDir(), "Tampered.app")
	if _, err = run(ctx, "/usr/bin/ditto", target, tampered); err != nil {
		t.Fatal(err)
	}
	info := filepath.Join(tampered, "Contents", "Resources", "Migration", "FilmDevelop.app", "Contents", "Info.plist")
	if err = os.WriteFile(info, []byte("damaged"), 0644); err != nil {
		t.Fatal(err)
	}
	if bad, e := prepareIdentityMigration(ctx, tampered); e == nil || bad != nil {
		if bad != nil {
			bad.Discard()
		}
		t.Fatal("被修改的內含 App 不應允許識別移轉")
	}
}

func TestMigratedAppUsesStandardUpdates(t *testing.T) {
	target := os.Getenv("FILMDEVELOP_MIGRATED_SMOKE_APP")
	if target == "" {
		t.Skip("未指定已移轉 App")
	}
	info, err := metadata(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	current := Version{info["CFBundleShortVersionString"].(string), info["CFBundleVersion"].(string)}
	build, err := strconv.Atoi(current.Build)
	if err != nil {
		t.Fatal(err)
	}
	next := Version{current.Version, strconv.Itoa(build + 1)}
	name := "FilmDevelop-" + next.Version + "-build" + next.Build + "-macos-arm64.dmg"
	// 下一版只提供標準包，確認真實移轉後的識別不再依賴 FilmYourPhoto。
	release := Release{Tag: next.Tag(), Assets: []Asset{{Name: name,
		URL:  "https://github.com/" + Repository + "/releases/download/" + next.Tag() + "/" + name,
		Size: 100, Digest: "sha256:" + strings.Repeat("a", 64)}}}
	_, asset, err := release.SelectForBundle(current, "darwin", info["CFBundleIdentifier"].(string))
	if err != nil || asset == nil || asset.Name != name {
		t.Fatal("移轉後仍需要舊相容包", err)
	}
}
