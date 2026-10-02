package application

import (
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/releasenotes"
)

func TestUpdateNoticePreservesBaselineAcrossRestart(t *testing.T) {
	a := testApp(t)
	prior := "v1.26.1002-build-1323"
	if err := a.store.SaveState("updates.json", updateState{Version: 1, Last: prior, Acknowledged: prior}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := a.loadUpdates(true); err != nil {
			t.Fatal(err)
		}
		if a.updateState.Previous != prior || a.updateState.Pending != currentVersion.Tag() {
			t.Fatalf("重新啟動遺失升級起點：%+v", a.updateState)
		}
	}
	count := 0
	a.emit = func(name string, value any) {
		if name != "handleUpdateComplete" {
			t.Fatal(name)
		}
		payload := value.(object)
		notes := payload["notes"].(releasenotes.Notice)
		if notes.PreviousTag != prior || len(notes.Releases) < 2 {
			t.Fatal("跨版摘要不完整", notes)
		}
		count++
	}
	if !a.deliverUpdateNotice() || !a.deliverUpdateNotice() || count != 2 {
		t.Fatal("未確認的摘要必須允許重送")
	}
	if err := a.acknowledgeUpdate(object{"tag": prior}); err == nil {
		t.Fatal("不得用舊標籤確認")
	}
	if err := a.acknowledgeUpdate(object{"tag": currentVersion.Tag()}); err != nil {
		t.Fatal(err)
	}
	if err := a.loadUpdates(true); err != nil {
		t.Fatal(err)
	}
	if a.deliverUpdateNotice() || a.updateState.Previous != "" {
		t.Fatal("已讀摘要不應在重新啟動後再次出現")
	}
}
