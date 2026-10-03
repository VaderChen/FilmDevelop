package application

import (
	"errors"

	"github.com/VaderChen/FilmDevelop/internal/storage"
)

type rawConfigurationSnapshot struct {
	backend, sourcePreview    string
	lensCorrection            bool
	subjectMask               *storage.SubjectMask
	forceSubject, skipSubject bool
}

// RAW 解析器與鏡頭校正共用交易；預覽成功前不把試用中的設定寫入偏好。
func (a *App) setRAWConfiguration(backend string, lensCorrection bool) error {
	a.mu.Lock()
	if a.rawSwitch != nil || a.previewBusy() {
		a.mu.Unlock()
		return errors.New("請等待目前照片處理完成")
	}
	previous := &rawConfigurationSnapshot{backend: a.rawDecoder, lensCorrection: a.preferences.LensCorrection,
		sourcePreview: a.sourcePreview, subjectMask: a.subjectMask, forceSubject: a.forceSubject, skipSubject: a.skipSubject}
	changed := previous.backend != backend || previous.lensCorrection != lensCorrection
	decoder, _ := a.renderInfo["rawDecoder"].(string)
	deferred := changed && a.source != "" && (decoder == "system" || decoder == "software")
	if deferred {
		a.rawSwitch = previous
	}
	a.rawDecoder, a.preferences.LensCorrection = backend, lensCorrection
	if previous.lensCorrection != lensCorrection {
		a.forceSubject = a.forceSubject || a.subjectMask != nil
		a.subjectMask = nil
		a.skipSubject = false
	}
	if changed {
		a.sourcePreview = ""
	}
	a.mu.Unlock()
	if !deferred {
		if err := a.savePreferences(); err != nil {
			a.mu.Lock()
			a.restoreRAWConfiguration(previous)
			a.mu.Unlock()
			return err
		}
	}
	if changed {
		a.preview()
	} else {
		a.state()
	}
	return nil
}

// 呼叫端持有 App.mu；原有影像與遮罩只在失敗時恢復。
func (a *App) restoreRAWConfiguration(previous *rawConfigurationSnapshot) {
	a.rawDecoder, a.preferences.LensCorrection = previous.backend, previous.lensCorrection
	a.sourcePreview, a.subjectMask = previous.sourcePreview, previous.subjectMask
	a.forceSubject, a.skipSubject = previous.forceSubject, previous.skipSubject
}
