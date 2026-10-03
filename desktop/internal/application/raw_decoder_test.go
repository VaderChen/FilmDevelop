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
	var state object
	a.emit = func(name string, payload any) {
		if name == "handleNativeState" {
			state = payload.(object)
		}
	}
	a.previewDone(a.revision, "", nil, &engine.NativeError{Code: "rawDecoderUnavailable", Message: "需要補充解碼器"})
	if state["rawDecoderRequired"] != true || state["previewFailed"] != true || a.outputPreview != "原有預覽" || a.dialog != nil {
		t.Fatal("缺少解碼器時應保留照片並透過狀態列提供安裝入口")
	}
	if err := a.setupRAWDecoder(); err != nil || a.dialog == nil || len(a.dialog.Choices) != 2 {
		t.Fatal("缺少官方下載與重新偵測選項", err)
	}
	for _, err := range []error{nil, context.Canceled, errors.New("磁碟空間不足"), &engine.NativeError{Code: "decodeFailed"}} {
		if needsRAWDecoder(err) {
			t.Fatal("與解碼器無關的錯誤不應要求安裝", err)
		}
	}
	a.previewDone(a.revision, "完成的預覽", []byte(`{}`), nil)
	if state["rawDecoderRequired"] != false || state["previewFailed"] != false || a.outputPreview != "完成的預覽" {
		t.Fatal("完成後仍留下安裝提示")
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
