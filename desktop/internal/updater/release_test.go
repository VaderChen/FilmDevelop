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
