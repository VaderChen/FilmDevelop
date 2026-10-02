package application

import "time"

// 一份執行中、一份最新參數；中間手勢不排隊、不寫磁碟。
// 像素運算仍由平台引擎處理。所有欄位由 App.mu 保護。
type adjustmentPreviewState struct {
	epoch, activeRevision, submittedEdit uint64
	pending, settling, settleReady       bool
}

const adjustmentSettleDelay = 150 * time.Millisecond

// 呼叫端持有 App.mu；等待清晰圖的空檔同樣屬於預覽處理中。
func (a *App) previewBusy() bool {
	return a.rendering || a.adjustmentPreview.settling || a.interaction != ""
}

// 呼叫端持有 App.mu；換圖、換底片及其他編輯都使舊手勢與計時器失效。
func (a *App) cancelAdjustmentPreview() {
	if a.previewTimer != nil {
		a.previewTimer.Stop()
		a.previewTimer = nil
	}
	a.adjustmentPreview = adjustmentPreviewState{epoch: a.adjustmentPreview.epoch + 1}
	a.interaction, a.historyGroup = "", ""
}

func (a *App) invalidatePreview() {
	a.cancelAdjustmentPreview()
	if a.cancel != nil {
		a.cancel()
	}
	a.revision++
	a.rendering = false
}

func (a *App) beginAdjustment(message object) {
	a.mu.Lock()
	defer a.mu.Unlock()
	id := stringValue(message, "interactionID")
	if id == "" || a.source == "" || message["photoGeneration"] != a.generation || message["style"] != a.selected || id == a.interaction {
		return
	}
	a.cancelAdjustmentPreview()
	a.interaction = id
}

func (a *App) endAdjustment(message object) error {
	a.mu.Lock()
	if a.interaction == "" || message["interactionID"] != a.interaction || message["photoGeneration"] != a.generation {
		a.mu.Unlock()
		return nil
	}
	a.interaction, a.historyGroup = "", ""
	a.adjustmentPreview.settling = true
	epoch := a.adjustmentPreview.epoch
	// 放開後短暫合併連續調整，再補處理圖；最新縮圖尚未完成時先讓它收尾。
	a.previewTimer = time.AfterFunc(adjustmentSettleDelay, func() { a.enqueueAdjustmentContinuation(epoch, true) })
	a.mu.Unlock()
	a.state()
	if err := a.persist(); err != nil {
		return err
	}
	return a.rememberDecorations()
}

func (a *App) enqueueAdjustmentContinuation(epoch uint64, settle bool) {
	select {
	case a.commands <- object{"action": "continueAdjustmentPreview", "epoch": epoch, "settle": settle}:
	case <-a.ctx.Done():
	}
}

func (a *App) continueAdjustment(message object) {
	a.mu.Lock()
	epoch, _ := message["epoch"].(uint64)
	if epoch == 0 || epoch != a.adjustmentPreview.epoch {
		a.mu.Unlock()
		return
	}
	if message["settle"] == true {
		a.adjustmentPreview.settleReady = true
	}
	if a.rendering {
		a.mu.Unlock()
		return
	}
	live := a.adjustmentPreview.pending
	settle := a.adjustmentPreview.settling && a.adjustmentPreview.settleReady
	a.mu.Unlock()
	if live || settle {
		a.startPreviewMode(false, live, epoch)
	}
}
