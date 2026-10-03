package application

import (
	"context"
	"errors"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/engine"
)

func TestMissingRAWDecoderCanBeInstalledWithoutLosingPreview(t *testing.T) {
	a := testApp(t)
	a.outputPreview = "原有預覽"
	var opened []string
	a.browserOpenURL = func(_ context.Context, url string) { opened = append(opened, url) }
	var state object
	a.emit = func(name string, payload any) {
		if name == "handleNativeState" {
			state = payload.(object)
		}
	}
	a.previewDone(a.revision, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable", Message: "需要補充解碼器"})
	if state["rawDecoderRequired"] != true || state["previewFailed"] != true || a.outputPreview != "原有預覽" || a.dialog == nil || len(opened) != 0 {
		t.Fatal("缺少解碼器時應保留照片並先詢問，不可直接開啟瀏覽器")
	}
	if err := a.resolveDialog(object{"id": a.dialog.ID, "cancelled": true}); err != nil {
		t.Fatal(err)
	}
	a.previewDone(a.revision, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable"})
	if a.dialog != nil || len(opened) != 0 {
		t.Fatal("取消後不應自動開網頁或重複詢問同一張照片")
	}
	if err := a.setupRAWDecoder(); err != nil || a.dialog == nil || len(a.dialog.Choices) != 2 {
		t.Fatal("缺少官方下載與重新偵測選項", err)
	}
	if err := a.resolveDialog(object{"id": a.dialog.ID, "value": "download"}); err != nil {
		t.Fatal(err)
	}
	if len(opened) != 1 || opened[0] != rawDecoderDownloadURL {
		t.Fatal("確認後應只開啟 Adobe 官方下載頁面", opened)
	}
	a.previewDone(a.revision, "完成的預覽", []byte(`{}`), nil)
	if state["rawDecoderRequired"] != false || state["previewFailed"] != false || a.outputPreview != "完成的預覽" {
		t.Fatal("完成後仍留下安裝提示")
	}
}

func TestRAWDecoderConfirmationWaitsForCurrentDialog(t *testing.T) {
	a := testApp(t)
	_ = a.showDialog("目前操作", "", "", []dialogChoice{{ID: "close"}}, func(string) error { return nil })
	current := a.dialog.ID
	a.previewDone(a.revision, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable"})
	if a.dialog.ID != current {
		t.Fatal("解碼器提示覆蓋了目前操作")
	}
	if err := a.resolveDialog(object{"id": current, "value": "close"}); err != nil || a.dialog == nil || a.dialog.ID == current {
		t.Fatal("目前操作結束後未顯示解碼器確認", err)
	}
	if err := a.resolveDialog(object{"id": a.dialog.ID, "cancelled": true}); err != nil {
		t.Fatal(err)
	}
	a.generation = identifier()
	a.previewDone(a.revision, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable"})
	if a.dialog == nil {
		t.Fatal("新照片缺少解碼器時未重新確認")
	}
	stale := a.dialog.ID
	a.generation = identifier()
	a.previewDone(a.revision, "其他照片", []byte(`{}`), nil)
	opened := false
	a.browserOpenURL = func(context.Context, string) { opened = true }
	if err := a.resolveDialog(object{"id": stale, "value": "download"}); err == nil || opened {
		t.Fatal("過期照片的對話框不應開啟瀏覽器")
	}
}

func TestRAWDecoderConfirmationIgnoresUnrelatedAndObsoleteFailures(t *testing.T) {
	a := testApp(t)
	for _, err := range []error{nil, context.Canceled, errors.New("磁碟空間不足"), &engine.NativeError{Code: "decodeFailed"}} {
		a.previewDone(a.revision, "", nil, err)
		if a.dialog != nil || needsRAWDecoder(err) {
			t.Fatal("與解碼器無關的錯誤不應要求安裝", err)
		}
	}
	a.revision++
	a.previewDone(a.revision-1, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable"})
	if a.dialog != nil {
		t.Fatal("過期預覽不應顯示安裝提示")
	}
	_ = a.showDialog("目前操作", "", "", []dialogChoice{{ID: "close"}}, func(string) error { return nil })
	current := a.dialog.ID
	a.previewDone(a.revision, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable"})
	a.previewDone(a.revision, "已成功", []byte(`{}`), nil)
	if err := a.resolveDialog(object{"id": current, "value": "close"}); err != nil || a.dialog != nil {
		t.Fatal("已成功解碼後不應再顯示等待中的安裝提示", err)
	}
}

func TestRetryAfterInstallingRAWDecoderAlsoRefreshesFailedThumbnails(t *testing.T) {
	a := testApp(t)
	a.thumbnailFailed["目前照片"] = true
	a.thumbnailFailed["列表另一張照片"] = true
	a.retryPreview()
	if len(a.thumbnailFailed) != 0 {
		t.Fatal("重新偵測後仍阻擋列表縮圖載入")
	}
}
