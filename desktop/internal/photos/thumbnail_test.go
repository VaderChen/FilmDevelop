package photos

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
)

func TestThumbnailPaddingUsesSourceGeometry(t *testing.T) {
	for _, portrait := range []bool{false, true} {
		w, h, cw, ch := 256, 192, 256, 171
		if portrait {
			w, h, cw, ch = h, w, ch, cw
		}
		bitmap := image.NewRGBA(image.Rect(0, 0, w, h))
		rect := image.Rect((w-cw)/2, (h-ch)/2, (w-cw)/2+cw, (h-ch)/2+ch)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				c := color.RGBA{0, 0, 0, 255}
				if image.Pt(x, y).In(rect) {
					c = color.RGBA{uint8(50 + x%100), uint8(40 + y%120), 80, 255}
				}
				bitmap.SetRGBA(x, y, c)
			}
		}
		var encoded bytes.Buffer
		if err := jpeg.Encode(&encoded, bitmap, &jpeg.Options{Quality: 72}); err != nil {
			t.Fatal(err)
		}
		original := encoded.Bytes()
		// 真實 TIFF 目錄提供來源比例；標準 EXIF 方向會套用到來源尺寸。
		data := make([]byte, 50)
		copy(data, "II")
		order := binary.LittleEndian
		order.PutUint16(data[2:], 42)
		order.PutUint32(data[4:], 8)
		order.PutUint16(data[8:], 3)
		orientation := uint32(1)
		if portrait {
			orientation = 6
		}
		for i, v := range [][2]uint32{{256, 6000}, {257, 4000}, {274, orientation}} {
			p := data[10+i*12:]
			order.PutUint16(p, uint16(v[0]))
			order.PutUint16(p[2:], 4)
			order.PutUint32(p[4:], 1)
			order.PutUint32(p[8:], v[1])
		}
		path := filepath.Join(t.TempDir(), "sample.dng")
		_ = os.WriteFile(path, data, 0600)
		out := NormalizeThumbnail(path, original)
		config, err := jpeg.DecodeConfig(bytes.NewReader(out))
		if err != nil || config.Width != cw || config.Height != ch {
			t.Fatalf("黑邊未依來源比例移除：%+v %v", config, err)
		}
		if !bytes.Equal(NormalizeThumbnail(path, out), out) {
			t.Fatal("重複正規化改變縮圖")
		}
		if !bytes.Equal(NormalizeThumbnail(path+"missing", original), original) {
			t.Fatal("沒有來源尺寸仍裁去黑邊")
		}
		// 同樣的 4:3 容器，外緣存在實際亮部時不可裁掉。
		bitmap.SetRGBA(0, 0, color.RGBA{220, 220, 220, 255})
		encoded.Reset()
		_ = jpeg.Encode(&encoded, bitmap, &jpeg.Options{Quality: 90})
		if !bytes.Equal(NormalizeThumbnail(path, encoded.Bytes()), encoded.Bytes()) {
			t.Fatal("誤裁實際影像內容")
		}
		// 全暗照片即使尺寸不符，也沒有證據表明外緣是容器補邊。
		encoded.Reset()
		_ = jpeg.Encode(&encoded, image.NewGray(image.Rect(0, 0, w, h)), nil)
		if !bytes.Equal(NormalizeThumbnail(path, encoded.Bytes()), encoded.Bytes()) {
			t.Fatal("誤裁全暗照片")
		}
	}
}
