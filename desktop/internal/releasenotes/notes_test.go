package releasenotes

import (
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/updater"
)

func TestUpgradeRangeAndPlatform(t *testing.T) {
	current, _ := updater.Parse(history.Releases[0].Tag)
	for _, test := range []struct {
		previous string
		count    int
		fallback bool
	}{
		{history.Releases[0].PreviousTag, 1, false},
		{history.Releases[1].PreviousTag, 2, false},
		{history.Releases[2].PreviousTag, 3, false},
		{"", 1, true}, {"invalid", 1, true}, {current.Tag(), 1, true},
	} {
		for _, platform := range []string{"darwin", "windows"} {
			n := ForUpgrade(current, test.previous, platform)
			if len(n.Releases) != test.count || n.BaselineUnknown != test.fallback {
				t.Fatalf("%s/%s：錯誤的比較範圍：%+v", test.previous, platform, n)
			}
			for _, release := range n.Releases {
				for _, change := range release.Changes {
					if !change.InApp || len(change.Platforms) > 0 && change.Platforms[0] != platform {
						t.Fatalf("不適用的項目進入摘要：%+v", change)
					}
					for _, language := range []string{"traditionalChinese", "english", "japanese", "korean"} {
						if change.Text[language] == "" || n.Labels[change.Kind][language] == "" {
							t.Fatal("缺少翻譯：", language)
						}
					}
				}
			}
		}
	}
}

func TestEarlierAndHistoricalUpgrade(t *testing.T) {
	current, _ := updater.Parse(history.Releases[1].Tag)
	n := ForUpgrade(current, "v1.26.0101-build-1", "windows")
	if !n.EarlierHistory || len(n.Releases) != len(history.Releases)-1 || n.Releases[0].Tag != current.Tag() {
		t.Fatalf("舊版比較不得包含未來版本：%+v", n)
	}
	for _, release := range n.Releases {
		version, err := updater.Parse(release.Tag)
		if err != nil || version.After(current) {
			t.Fatal("歷史更新摘要包含未來版本：", release.Tag)
		}
	}
}
