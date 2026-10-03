package application

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStartupProgressReplaysLatestAndDoesNotReopen(t *testing.T) {
	a := testApp(t)
	var events []startupProgress
	a.emit = func(name string, payload any) {
		if name == "handleHostStartup" {
			events = append(events, payload.(startupProgress))
		}
	}
	a.reportStartup("保存舊版照片紀錄", true, 0, 100, "a.json")
	a.startupLastSent = time.Now().Add(time.Hour) // 模擬節流期間 WebView 才連上。
	a.reportStartup("保存舊版照片紀錄", true, 57, 100, "b.json")
	if len(events) != 1 {
		t.Fatal("進度未節流", events)
	}
	a.replayStartup()
	if p := events[1]; p.Completed != 57 || p.Item != "b.json" || !p.Active || p.Revision <= events[0].Revision {
		t.Fatal("晚連上的介面未取得最新進度", p)
	}
	a.reportStartup("保存舊版照片紀錄", true, 100, 100, "")
	if events[len(events)-1].Completed != 100 {
		t.Fatal("階段完成被節流")
	}
	a.finishStartup()
	a.reportStartup("保存舊版照片紀錄", true, 0, 100, "stale")
	a.replayStartup()
	if p := events[len(events)-1]; p.Active || p.Item == "stale" {
		t.Fatal("完成後的舊進度重新鎖住介面", p)
	}
}

func TestLegacyArchiveReportsRealProgressAndPreservesSource(t *testing.T) {
	a, photo, legacy, _ := legacyPhotoFixture(t)
	before, err := os.ReadFile(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err = a.store.SaveState("browser.json", browserState{Version: 1, Directory: filepath.Dir(photo)}); err != nil {
		t.Fatal(err)
	}
	var events []startupProgress
	a.emit = func(name string, payload any) {
		if name == "handleHostStartup" {
			events = append(events, payload.(startupProgress))
		}
	}
	if err = a.archiveLegacyPhotos(); err != nil {
		t.Fatal(err)
	}
	completed := map[string]int{}
	for _, p := range events {
		if p.Completed < 0 || p.Completed > p.Total {
			t.Fatal("錯誤的實際處理數", p)
		}
		if p.Total > 0 && p.Completed == p.Total {
			completed[p.Stage] = p.Total
		}
	}
	if completed["保存舊版照片紀錄"] != 2 || completed["移轉照片調整與分類"] != 1 {
		t.Fatal("備份及照片進度不符合實際檔案", completed)
	}
	after, _ := os.ReadFile(legacy)
	archived, _ := os.ReadFile(filepath.Join(a.store.Root(), "legacy", "PhotoEdits", filepath.Base(legacy)))
	if !bytes.Equal(before, after) || !bytes.Equal(before, archived) {
		t.Fatal("進度回報改動了移轉來源或備份")
	}
	// 重新啟動使用已保存資料，仍能走到完成，不依賴首次才會出現的步驟。
	if err = a.archiveLegacyPhotos(); err != nil {
		t.Fatal(err)
	}
	a.finishStartup()
	if events[len(events)-1].Active {
		t.Fatal("完成後等待狀態未解除")
	}
}

func TestLegacyArchiveCancellationStillAllowsStartupToFinish(t *testing.T) {
	a, _, _, _ := legacyPhotoFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a.ctx = ctx
	if err := a.archiveLegacyPhotos(); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	a.finishStartup()
	if a.startupProgress.Active {
		t.Fatal("失敗後等待狀態未解除")
	}
}
