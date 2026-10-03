package application

import (
	"errors"

	"github.com/VaderChen/FilmDevelop/internal/engine"
)

// 導向 Adobe 提供的官方下載與安裝說明；安裝與授權由使用者完成。
// FilmDevelop 不鏡像、不拆包，也不隨安裝檔散布 Adobe Converter。
const rawDecoderDownloadURL = "https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html"

func needsRAWDecoder(err error) bool {
	var native *engine.NativeError
	return errors.As(err, &native) && native.Code == "rawDecoderUnavailable"
}

func (a *App) setupRAWDecoder() error {
	return a.showRAWDecoderDialog(false)
}

func (a *App) offerRAWDecoder() {
	_ = a.showRAWDecoderDialog(true)
}

func (a *App) showRAWDecoderDialog(automatic bool) error {
	return a.showDialogWhen(func() bool {
		if automatic && (a.closing || a.rendering || a.dialog != nil || !needsRAWDecoder(a.previewError) || a.rawDecoderPromptGeneration == a.generation) {
			return false
		}
		// 同一張照片只自動提示一次，取消後仍可從照片下方重新開啟。
		a.rawDecoderPromptGeneration = a.generation
		return true
	}, "補充 RAW 解碼器", "此 RAW 需要另外安裝 Adobe DNG Converter。按「Adobe 官方下載」後，會用預設瀏覽器開啟 Adobe 下載頁面。\n請下載適合系統的版本，完成授權與安裝後，回到照片下方按「重新載入預覽」。原始照片與拍攝 EXIF 會保留。", "",
		[]dialogChoice{{ID: "download", Label: "Adobe 官方下載"}, {ID: "retry", Label: "重新偵測", Role: "secondary"}}, func(choice string) error {
			if choice == "download" {
				a.browserOpenURL(a.ctx, rawDecoderDownloadURL)
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
