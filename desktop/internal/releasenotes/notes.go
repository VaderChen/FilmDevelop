// Package releasenotes 提供離線、逐版且與文件共用的四語更新紀錄。
package releasenotes

import (
	_ "embed"
	"encoding/json"

	"github.com/VaderChen/FilmDevelop/internal/updater"
)

//go:embed history.json
var data []byte

type Text map[string]string
type Change struct {
	Kind      string   `json:"kind"`
	Text      Text     `json:"text"`
	Platforms []string `json:"platforms,omitempty"`
	InApp     bool     `json:"inApp"`
}
type Release struct {
	Tag         string   `json:"tag"`
	PreviousTag string   `json:"previousTag"`
	Changes     []Change `json:"changes"`
}
type History struct {
	Schema   int             `json:"schema"`
	Labels   map[string]Text `json:"labels"`
	Releases []Release       `json:"releases"`
}
type Notice struct {
	Labels          map[string]Text `json:"labels"`
	PreviousTag     string          `json:"previousTag"`
	BaselineUnknown bool            `json:"baselineUnknown"`
	EarlierHistory  bool            `json:"earlierHistory"`
	Releases        []Release       `json:"releases"`
}

var history History

func init() {
	if err := json.Unmarshal(data, &history); err != nil {
		panic(err)
	}
}

// ForUpgrade 使用實際升級前版本；沒有紀錄時只比較最近一次發布。
// 不因未知版本而把所有歷史功能冒充成本次新增。
func ForUpgrade(current updater.Version, previous, platform string) Notice {
	notice := Notice{Labels: history.Labels, Releases: []Release{}}
	prior, err := updater.Parse(previous)
	if err != nil || !current.After(prior) {
		notice.BaselineUnknown = true
		for _, release := range history.Releases {
			if release.Tag == current.Tag() {
				previous = release.PreviousTag
				prior, _ = updater.Parse(previous)
				break
			}
		}
	}
	notice.PreviousTag = previous
	for _, release := range history.Releases {
		version, err := updater.Parse(release.Tag)
		if err != nil || version.After(current) || !version.After(prior) {
			continue
		}
		filtered := Release{Tag: release.Tag, PreviousTag: release.PreviousTag, Changes: []Change{}}
		for _, change := range release.Changes {
			applicable := len(change.Platforms) == 0
			for _, target := range change.Platforms {
				applicable = applicable || target == platform
			}
			if change.InApp && applicable {
				filtered.Changes = append(filtered.Changes, change)
			}
		}
		notice.Releases = append(notice.Releases, filtered)
	}
	if len(history.Releases) > 0 {
		oldest, _ := updater.Parse(history.Releases[len(history.Releases)-1].PreviousTag)
		notice.EarlierHistory = oldest.After(prior)
	}
	return notice
}
