package exifmeta

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestDisplaySizeUsesRawCropAndOrientation(t *testing.T) {
	for _, order := range []binary.ByteOrder{binary.LittleEndian, binary.BigEndian} {
		for _, orientation := range []uint32{1, 6, 8} {
			data := make([]byte, 256)
			copy(data, "II")
			if order == binary.BigEndian {
				copy(data, "MM")
			}
			order.PutUint16(data[2:], 42)
			order.PutUint32(data[4:], 8)
			write := func(offset int, fields []entry, next uint32) {
				order.PutUint16(data[offset:], uint16(len(fields)))
				for i, e := range fields {
					p := data[offset+2+i*12:]
					order.PutUint16(p, e.tag)
					order.PutUint16(p[2:], e.kind)
					order.PutUint32(p[4:], e.count)
					copy(p[8:12], e.data)
				}
				order.PutUint32(data[offset+2+len(fields)*12:], next)
			}
			// IFD0 是 4:3 縮圖；SubIFD 才是 3:2 的感光資料及有效裁切。
			write(8, []entry{numeric(254, 1, false, order), numeric(256, 256, false, order), numeric(257, 192, false, order), numeric(274, orientation, true, order), numeric(330, 100, false, order)}, 0)
			crop := numeric(50720, 200, false, order)
			crop.kind = 5
			crop.count = 2
			write(100, []entry{numeric(256, 6080, false, order), numeric(257, 4056, false, order), crop}, 100) // 循環鏈不得卡住。
			order.PutUint32(data[200:], 6000)
			order.PutUint32(data[204:], 1)
			order.PutUint32(data[208:], 4000)
			order.PutUint32(data[212:], 1)
			path := filepath.Join(t.TempDir(), "sample.dng")
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			w, h := DisplaySize(path)
			wantW, wantH := 6000., 4000.
			if orientation >= 5 {
				wantW, wantH = wantH, wantW
			}
			if w != wantW || h != wantH {
				t.Fatalf("%v orientation %d: %v x %v", order, orientation, w, h)
			}
			order.PutUint32(data[204:], 0)
			_ = os.WriteFile(path, data, 0600)
			w, h = DisplaySize(path)
			if w*h != 6080*4056 {
				t.Fatalf("無效有理數未安全退回像素尺寸：%v x %v", w, h)
			}
		}
	}
}

func TestDisplaySizeRejectsUnknownAndBrokenFiles(t *testing.T) {
	for _, data := range [][]byte{nil, []byte("not a TIFF"), {'I', 'I', 42, 0, 255, 255, 255, 255}} {
		path := filepath.Join(t.TempDir(), "unknown.dng")
		_ = os.WriteFile(path, data, 0600)
		if w, h := DisplaySize(path); w != 0 || h != 0 {
			t.Fatalf("錯誤尺寸：%v x %v", w, h)
		}
	}
}
