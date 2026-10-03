package application

import (
	"errors"

	"github.com/VaderChen/FilmDevelop/internal/engine"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// 導向 Adobe 提供的官方下載與安裝說明；安裝與授權由使用者完成。
// FilmDevelop 不鏡像、不拆包，也不隨安裝檔散布 Adobe Converter。
const rawDecoderDownloadURL = "https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html"

func needsRAWDecoder(err error) bool {
	var native *engine.NativeError
	return errors.As(err, &native) && native.Code == "rawDecoderUnavailable"
}

func (a *App) setupRAWDecoder() error {
	return a.showDialog("補充 RAW 解碼器", "此 RAW 需要 Adobe DNG Converter。請從 Adobe 官方下載適合系統的版本，依安裝程式完成授權與安裝，再回到這裡按「重新偵測」。\n安裝後會自動建立無損 RAW 快取，保留原始照片與拍攝 EXIF。", "",
		[]dialogChoice{{ID: "download", Label: "Adobe 官方下載"}, {ID: "retry", Label: "重新偵測", Role: "secondary"}}, func(choice string) error {
			if choice == "download" {
				wruntime.BrowserOpenURL(a.ctx, rawDecoderDownloadURL)
			} else if choice == "retry" {
				a.retryPreview()
			}
			return nil
		})
}

func (a *App) retryPreview() {
	a.mu.Lock()
	// 安裝解碼器或重新掛載來源後，可見列表也要重新偵測先前失敗的照片。
	clear(a.thumbnailFailed)
	a.mu.Unlock()
	a.directoryState()
	a.preview()
}
