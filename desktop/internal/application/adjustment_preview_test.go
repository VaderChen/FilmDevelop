package application

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

func TestAdjustmentPreviewCoalescesAndFinishesLatestRecipe(t *testing.T) {
	a := testApp(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	a.ctx = ctx
	t.Cleanup(func() { cancel(); a.workers.Wait() })
	a.source, a.outputPreview = "測試照片.raw", "原有影像"
	a.preferences.OriginalResolution = true
	started, release := make(chan contract.RenderJob, 8), make(chan struct{}, 8)
	a.services, _ = host.New(previewBackend{render: func(ctx context.Context, job contract.RenderJob) (json.RawMessage, error) {
		started <- job
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return json.RawMessage(`{"sourceWidth":6000,"sourceHeight":4000}`), os.WriteFile(job.Output.Path, job.Recipe.Adjustment, 0600)
	}})
	command := func(action string, fields object) {
		t.Helper()
		message := object{"action": action, "style": a.selected, "photoGeneration": a.generation, "interactionID": "手勢一"}
		for key, value := range fields {
			message[key] = value
		}
		if err := a.handle(message); err != nil {
			t.Fatal(err)
		}
	}
	readJob := func(value float64, live bool) {
		t.Helper()
		select {
		case job := <-started:
			if recipeFields(job.Recipe)["intensity"] != value || (job.PreviewMaxPixel == 1024) != live || job.Policy.FullResolution == live {
				t.Fatal("送到原生引擎的最新參數或解析度不符", recipeFields(job.Recipe)["intensity"], job.PreviewMaxPixel, job.Policy.FullResolution)
			}
		case <-ctx.Done():
			t.Fatal("未派送預覽")
		}
	}
	continuation := func() {
		t.Helper()
		select {
		case message := <-a.commands:
			if err := a.handle(message); err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("未接續最新工作")
		}
	}
	command("beginAdjustmentPreview", nil)
	command("updateAdjustment", object{"key": "intensity", "value": float64(10)})
	readJob(10, true)
	for value := 11; value <= 30; value++ {
		command("updateAdjustment", object{"key": "intensity", "value": float64(value)})
	}
	select {
	case <-started:
		t.Fatal("拖曳中建立了多個原生工作")
	default:
	}
	release <- struct{}{}
	a.workers.Wait()
	if a.previewError != nil || a.outputPreview == "原有影像" {
		t.Fatal("持續拖曳時丟棄了可顯示的中間結果", a.previewError)
	}
	continuation()
	readJob(30, true)
	command("endAdjustmentPreview", nil)
	a.mu.Lock()
	a.previewTimer.Stop()
	epoch := a.adjustmentPreview.epoch
	a.mu.Unlock()
	// 清晰圖計時到期時，最後一張編輯縮圖仍應先完成。
	a.continueAdjustment(object{"epoch": epoch, "settle": true})
	select {
	case <-started:
		t.Fatal("完整預覽搶先打斷最後縮圖")
	default:
	}
	release <- struct{}{}
	a.workers.Wait()
	continuation()
	readJob(30, false)
	release <- struct{}{}
	a.workers.Wait()
	if len(a.undo) != 1 || a.interaction != "" || a.rendering || a.adjustmentPreview.settling || a.previewError != nil {
		t.Fatal("手勢未完整結束，或一次拖曳產生多筆復原紀錄", len(a.undo), a.previewError)
	}
}

func TestOldAdjustmentCannotRestartAfterFilmSwitch(t *testing.T) {
	a := testApp(t)
	a.source = "測試照片.raw"
	a.beginAdjustment(object{"photoGeneration": a.generation, "style": a.selected, "interactionID": "舊手勢"})
	epoch := a.adjustmentPreview.epoch
	a.adjustmentPreview.pending, a.adjustmentPreview.settling = true, true
	if err := a.selectStyle("filmPortra400"); err != nil {
		t.Fatal(err)
	}
	revision := a.revision
	a.continueAdjustment(object{"epoch": epoch, "settle": true})
	if a.revision != revision || a.rendering || a.adjustmentPreview.pending || a.adjustmentPreview.settling {
		t.Fatal("過期計時器或舊手勢重啟了預覽")
	}
	if err := a.update(object{"photoGeneration": a.generation, "style": a.selected, "interactionID": "舊手勢", "key": "intensity", "value": float64(10)}); err == nil {
		t.Fatal("過期手勢修改了新底片")
	}
}
