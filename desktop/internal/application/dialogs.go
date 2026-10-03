package application

import "errors"

type dialogChoice struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Disabled bool   `json:"disabled,omitempty"`
	Role     string `json:"role,omitempty"`
}
type pendingDialog struct {
	ID, Generation string
	Choices        []dialogChoice
	Submit         func(string) error
	Cancel         func()
	Menu           bool
}

func (a *App) showDialog(title, detail, value string, choices []dialogChoice, submit func(string) error) error {
	return a.showDialogWhen(nil, title, detail, value, choices, submit)
}

// 條件在鎖內檢查，讓背景提示可等待現有操作完成，不會覆蓋其他對話框。
func (a *App) showDialogWhen(eligible func() bool, title, detail, value string, choices []dialogChoice, submit func(string) error) error {
	a.mu.Lock()
	if eligible != nil && !eligible() {
		a.mu.Unlock()
		return nil
	}
	id := identifier()
	a.dialog = &pendingDialog{ID: id, Generation: a.generation, Choices: choices, Submit: submit}
	a.mu.Unlock()
	a.reply("handleHostDialog", object{"id": id, "title": title, "detail": detail, "value": value, "choices": choices})
	return nil
}
func (a *App) resolveDialog(message object) error {
	a.mu.Lock()
	d := a.dialog
	if d == nil || message["id"] != d.ID {
		a.mu.Unlock()
		// 關閉舊選單的事件可能晚於下一份選單；取消不應產生錯誤提示。
		if message["cancelled"] == true {
			return nil
		}
		return errors.New("此對話框已失效")
	}
	a.dialog = nil
	current := d.Generation == a.generation
	a.mu.Unlock()
	defer a.offerRAWDecoder()
	if message["cancelled"] == true {
		if d.Cancel != nil {
			d.Cancel()
		}
		return nil
	}
	if !current {
		return errors.New("照片已切換，操作已取消")
	}
	value, _ := message["value"].(string)
	if d.Menu || len(d.Choices) > 0 {
		ok := false
		for _, c := range d.Choices {
			if c.ID == value && !c.Disabled {
				ok = true
			}
		}
		if !ok {
			return errors.New("選項不符")
		}
	}
	return d.Submit(value)
}

var commitActions = map[string]bool{
	"setComputeBackend": true,
	"openNativeFile":    true,
	"saveCustomFilm":    true, "deleteCustomFilm": true, "showCustomFilmMenu": true, "showRecentPhotoDirectories": true,
	"undoEdit": true, "redoEdit": true, "importColorCalibration": true, "clearColorCalibration": true, "applyStyle": true,
	"saveImage": true, "browseFiles": true, "browsePhotoDirectory": true, "selectDirectoryPhoto": true, "showPreviewMenu": true, "setStyle": true,
}
