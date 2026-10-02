// Package updater 共用版本判斷、下載驗證；安裝僅接受對應平台的混合套件。
package updater

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/transfer"
)

type Version struct {
	Version string `json:"version"`
	Build   string `json:"build"`
}
type Asset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Size   int64  `json:"size"`
	Digest string `json:"digest"`
}
type Release struct {
	Tag        string  `json:"tag_name"`
	Draft      bool    `json:"draft"`
	Prerelease bool    `json:"prerelease"`
	Assets     []Asset `json:"assets"`
}

const Repository = "VaderChen/FilmDevelop"

const MacBundleIdentifier = "person.vader.FilmDevelop.GoDevelopment"
const LegacyMacBundleIdentifier = "person.vader.PhotoStyleApp"

var versionTag = regexp.MustCompile(`^v?(\d+\.\d+\.\d+)-build-?(\d+)$`)
var digestPattern = regexp.MustCompile(`^sha256:[a-fA-F0-9]{64}$`)

func Parse(tag string) (Version, error) {
	parts := versionTag.FindStringSubmatch(tag)
	if parts == nil {
		return Version{}, errors.New("版本標籤無法辨識")
	}
	return Version{parts[1], parts[2]}, nil
}
func (v Version) Tag() string { return "v" + v.Version + "-build-" + v.Build }
func (v Version) After(other Version) bool {
	left := strings.Split(v.Version+"."+v.Build, ".")
	right := strings.Split(other.Version+"."+other.Build, ".")
	if len(left) != 4 || len(right) != 4 {
		return false
	}
	for i := range left {
		l, e := strconv.ParseUint(left[i], 10, 32)
		r, f := strconv.ParseUint(right[i], 10, 32)
		if e != nil || f != nil {
			return false
		}
		if l != r {
			return l > r
		}
	}
	return false
}
func (r Release) Select(current Version, platform string) (Version, *Asset, error) {
	return r.SelectForBundle(current, platform, "")
}

// 同一份 Go 程式支援既有兩種 Mac 身分；選擇相符簽章套件，維持後續更新。
func (r Release) SelectForBundle(current Version, platform, identifier string) (Version, *Asset, error) {
	version, err := Parse(r.Tag)
	if err != nil {
		return Version{}, nil, err
	}
	if r.Draft || r.Prerelease || !version.After(current) {
		return version, nil, nil
	}
	suffix := ""
	switch platform {
	case "darwin":
		suffix = "macos-arm64.dmg"
	case "windows":
		suffix = "windows-x64-setup.exe"
	default:
		return version, nil, errors.New("此平台未提供安裝套件")
	}
	name := "FilmDevelop-" + version.Version + "-build" + version.Build + "-" + suffix
	if platform == "darwin" {
		switch identifier {
		case "", MacBundleIdentifier:
		case LegacyMacBundleIdentifier:
			name = "FilmYourPhoto-" + version.Version + "-build-" + version.Build + "-arm64.dmg"
		default:
			return version, nil, errors.New("目前 Mac App 的識別碼不支援自動更新")
		}
	}
	for _, asset := range r.Assets {
		if asset.Name != name {
			continue
		}
		u, e := url.Parse(asset.URL)
		if e != nil || u.Scheme != "https" || u.Host != "github.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "/"+Repository+"/releases/download/"+r.Tag+"/"+name || asset.Size <= 0 || asset.Size > 8*1024*1024*1024 || !digestPattern.MatchString(asset.Digest) {
			return version, nil, errors.New("更新檔案網址、大小或 SHA-256 資訊不完整")
		}
		return version, &asset, nil
	}
	return version, nil, fmt.Errorf("新版 %s 尚未提供此平台的 Go 混合安裝套件", version.Tag())
}
func Latest(ctx context.Context) (Release, error) {
	var release Release
	err := transfer.ReadJSON(ctx, "https://api.github.com/repos/"+Repository+"/releases/latest", &release)
	return release, err
}
func Download(ctx context.Context, destination string, asset Asset, progress func(transfer.Progress)) error {
	return transfer.InstallDirectory(ctx, destination, []transfer.File{{Path: asset.Name, URL: asset.URL, Size: asset.Size, SHA256: strings.TrimPrefix(strings.ToLower(asset.Digest), "sha256:")}}, nil, progress)
}
