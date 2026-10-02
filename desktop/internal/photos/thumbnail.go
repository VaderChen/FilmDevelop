package photos

import (
	"bytes"
	"image"
	"image/jpeg"
	"math"

	"github.com/VaderChen/FilmDevelop/internal/exifmeta"
)

// NormalizeThumbnail 移除相機內嵌 JPEG 為容器比例補上的黑邊。
// 必須有原檔尺寸佐證，且預期裁去的區域都是對稱黑邊；不按機型猜測，
// 不裁切一般照片的暗部。只處理 256 px 顯示縮圖，原始影像與顯影不變。
func NormalizeThumbnail(path string, data []byte) []byte {
	w, h := exifmeta.DisplaySize(path)
	if w <= 0 || h <= 0 {
		return data
	}
	return trimThumbnailPadding(data, w/h)
}

func trimThumbnailPadding(data []byte, aspect float64) []byte {
	config, err := jpeg.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width > 512 || config.Height > 512 || aspect <= 0 || math.IsNaN(aspect) || math.IsInf(aspect, 0) {
		return data
	}
	w, h := config.Width, config.Height
	cropW, cropH := w, h
	if float64(w)/float64(h) < aspect {
		cropH = int(math.Round(float64(w) / aspect))
	} else {
		cropW = int(math.Round(float64(h) * aspect))
	}
	dx, dy := (w-cropW)/2, (h-cropH)/2
	// 忽略尺寸捨入；拒絕不合理的大幅裁切。
	if dx < 2 && dy < 2 || cropW < w*3/4 || cropH < h*3/4 {
		return data
	}
	bitmap, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		return data
	}
	rect := image.Rect(dx, dy, dx+cropW, dy+cropH)
	borderCount, borderSum, brightInside := 0, uint64(0), 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, b, _ := bitmap.At(x, y).RGBA()
			level := max(r, g, b) >> 8
			if image.Pt(x, y).In(rect) {
				if level > 32 {
					brightInside++
				}
				continue
			}
			// JPEG 邊界可能有一個像素的 ringing；檢查更外側的實際黑邊。
			if image.Pt(x, y).In(rect.Inset(-1)) {
				continue
			}
			if level > 40 {
				return data
			}
			borderCount++
			borderSum += uint64(level)
		}
	}
	if borderCount == 0 || borderSum > uint64(borderCount)*6 || brightInside < cropW*cropH/20 {
		return data
	}
	var encoded bytes.Buffer
	view, ok := bitmap.(interface {
		SubImage(image.Rectangle) image.Image
	})
	if !ok || jpeg.Encode(&encoded, view.SubImage(rect), &jpeg.Options{Quality: 90}) != nil {
		return data
	}
	return encoded.Bytes()
}
