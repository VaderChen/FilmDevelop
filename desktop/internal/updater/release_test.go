package updater

import (
	"strings"
	"testing"
)

func TestReleaseRequiresMatchingHybridPackage(t *testing.T) {
	current := Version{"1.26.0924", "1107"}
	version := Version{"1.26.1001", "1200"}
	name := "FilmDevelop-1.26.1001-build1200-windows-x64-setup.exe"
	asset := Asset{Name: name, URL: "https://github.com/" + Repository + "/releases/download/" + version.Tag() + "/" + name, Size: 100, Digest: "sha256:" + strings.Repeat("a", 64)}
	release := Release{Tag: version.Tag(), Assets: []Asset{asset}}
	_, selected, err := release.Select(current, "windows")
	if err != nil || selected == nil {
		t.Fatal(err)
	}
	if _, _, err = release.Select(current, "darwin"); err == nil {
		t.Fatal("接受錯誤平台套件")
	}
	release.Assets[0].Digest = ""
	if _, _, err = release.Select(current, "windows"); err == nil {
		t.Fatal("未驗證下載摘要")
	}
	release.Assets[0] = asset
	release.Prerelease = true
	if _, selected, err = release.Select(current, "windows"); err != nil || selected != nil {
		t.Fatal("接受預覽 Release")
	}
	if current.After(version) || !version.After(current) {
		t.Fatal("版本順序錯誤")
	}
}

func TestMacUpdatePreservesInstalledIdentity(t *testing.T) {
	current, next := Version{"1.26.0930", "1745"}, Version{"1.26.1002", "1300"}
	modern := "FilmDevelop-1.26.1002-build1300-macos-arm64.dmg"
	legacy := "FilmYourPhoto-1.26.1002-build-1300-arm64.dmg"
	release := Release{Tag: next.Tag()}
	for _, name := range []string{modern, legacy} {
		release.Assets = append(release.Assets, Asset{Name: name,
			URL:  "https://github.com/" + Repository + "/releases/download/" + next.Tag() + "/" + name,
			Size: 100, Digest: "sha256:" + strings.Repeat("a", 64)})
	}
	for identifier, name := range map[string]string{MacBundleIdentifier: modern, LegacyMacBundleIdentifier: legacy} {
		_, asset, err := release.SelectForBundle(current, "darwin", identifier)
		if err != nil || asset == nil || asset.Name != name {
			t.Fatalf("%s 選錯套件：%v / %v", identifier, asset, err)
		}
	}
	if _, _, err := release.SelectForBundle(current, "darwin", "unrelated.app"); err == nil {
		t.Fatal("不應接受不明 App 身分")
	}
	release.Assets = release.Assets[:1]
	if _, _, err := release.SelectForBundle(current, "darwin", LegacyMacBundleIdentifier); err == nil {
		t.Fatal("相容包缺失時不得回退到不相符的 App")
	}
}
