package application

import "time"

// 啟動工作尚未接收一般 UI 指令；進度使用獨立快照，避免讀取載入中的資料。
type startupProgress struct {
	Active    bool   `json:"active"`
	Migration bool   `json:"migration"`
	Stage     string `json:"stage"`
	Item      string `json:"item"`
	Completed int    `json:"completed"`
	Total     int    `json:"total"`
	Language  string `json:"language"`
	Revision  uint64 `json:"revision"`
}

func (a *App) reportStartup(stage string, migration bool, completed, total int, item string) {
	a.startupMu.Lock()
	defer a.startupMu.Unlock()
	if !a.startupProgress.Active {
		return
	}
	p := &a.startupProgress
	changed := p.Stage != stage || p.Total != total || p.Migration != migration
	p.Stage, p.Migration, p.Completed, p.Total, p.Item = stage, migration, completed, total, item
	p.Revision++
	// 大量小檔只更新最新快照，不讓進度事件塞滿 WebView；階段與完成必須即時送出。
	if changed || completed == total || time.Since(a.startupLastSent) >= 100*time.Millisecond {
		a.startupLastSent = time.Now()
		a.reply("handleHostStartup", *p)
	}
}

func (a *App) replayStartup() {
	a.startupMu.Lock()
	defer a.startupMu.Unlock()
	a.reply("handleHostStartup", a.startupProgress)
}

func (a *App) finishStartup() {
	a.startupMu.Lock()
	defer a.startupMu.Unlock()
	a.startupProgress.Active = false
	a.startupProgress.Revision++
	a.reply("handleHostStartup", a.startupProgress)
}
