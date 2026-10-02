package exifmeta

import (
	"math"
	"os"
)

// DisplaySize 只讀取 TIFF／RAW 的尺寸目錄，不解碼感光資料。未知格式回傳零，
// 不能以內嵌 JPEG 的大小推測原照片比例。DNG 優先使用 DefaultCropSize。
func DisplaySize(path string) (width, height float64) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	order, first, err := tiffHeader(f)
	if err != nil {
		return
	}
	values := func(e entry) []float64 {
		if e.count > 32 {
			return nil
		}
		var out []float64
		for i := uint32(0); i < e.count; i++ {
			var v float64
			switch e.kind {
			case 3:
				v = float64(order.Uint16(e.data[i*2:]))
			case 4:
				v = float64(order.Uint32(e.data[i*4:]))
			case 5:
				den := order.Uint32(e.data[i*8+4:])
				if den == 0 {
					return nil
				}
				v = float64(order.Uint32(e.data[i*8:])) / float64(den)
			default:
				return nil
			}
			out = append(out, v)
		}
		return out
	}
	priority, orientation := 0, 1
	consider := func(w, h float64, rank int) {
		if w < 1 || h < 1 || w > 100000 || h > 100000 {
			return
		}
		if rank > priority || rank == priority && w*h > width*height {
			width, height, priority = w, h, rank
		}
	}
	pending, seen := []uint32{first}, map[uint32]bool{}
	for len(pending) > 0 && len(seen) < 32 {
		off := pending[0]
		pending = pending[1:]
		if off == 0 || seen[off] {
			continue
		}
		seen[off] = true
		d, next, err := readDirectory(f, off, order, func(tag uint16) bool {
			switch tag {
			case 254, 256, 257, 274, 330, 34665, 40962, 40963, 50720:
				return true
			}
			return false
		})
		if err != nil {
			continue
		}
		one := func(tag uint16) float64 {
			v := values(d[tag])
			if len(v) == 1 {
				return v[0]
			}
			return 0
		}
		if off == first && one(274) >= 1 && one(274) <= 8 {
			orientation = int(one(274))
		}
		if int(one(254))&1 == 0 {
			consider(one(256), one(257), 1)
			if crop := values(d[50720]); len(crop) == 2 {
				consider(crop[0], crop[1], 3)
			}
		}
		consider(one(40962), one(40963), 2)
		for _, tag := range []uint16{330, 34665} {
			for _, p := range values(d[tag]) {
				if p > 0 && p <= math.MaxUint32 && math.Trunc(p) == p {
					pending = append(pending, uint32(p))
				}
			}
		}
		if next != 0 {
			pending = append(pending, next)
		}
	}
	if orientation >= 5 {
		width, height = height, width
	}
	return
}
