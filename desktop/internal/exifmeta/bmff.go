package exifmeta

import (
	"context"
	"encoding/binary"
	"io"
)

// CR3 的拍攝目錄分置於 CMT1／2／4。依 BMFF 邊界讀取，避免將欄位中的
// TIFF 標頭備份誤認為另一份 EXIF，造成偏移位址與拍攝時間錯誤。
func readBMFF(ctx context.Context, r io.ReaderAt, size int64) Metadata {
	m := empty()
	remaining := 4096
	var walk func(int64, int64, int)
	walk = func(start, end int64, depth int) {
		if depth > 8 {
			return
		}
		for pos := start; pos+8 <= end && remaining > 0 && ctx.Err() == nil; {
			remaining--
			h, err := readAt(r, pos, 8)
			if err != nil {
				return
			}
			n := uint64(binary.BigEndian.Uint32(h))
			header := int64(8)
			if n == 1 {
				b, e := readAt(r, pos+8, 8)
				if e != nil {
					return
				}
				n = binary.BigEndian.Uint64(b)
				header = 16
			} else if n == 0 {
				n = uint64(end - pos)
			}
			if n < uint64(header) || n > uint64(end-pos) {
				return
			}
			limit := pos + int64(n)
			switch string(h[4:]) {
			case "moov":
				walk(pos+header, limit, depth+1)
			case "uuid":
				walk(pos+header+16, limit, depth+1)
			case "CMT1", "CMT2", "CMT4":
				part := io.NewSectionReader(r, pos+header, int64(n)-header)
				order, offset, e := tiffHeader(part)
				if e != nil {
					break
				}
				accept := rootCapture
				target := m.root
				if string(h[4:]) == "CMT2" {
					accept = photoCapture
					target = m.photo
				}
				if string(h[4:]) == "CMT4" {
					accept = func(tag uint16) bool { return tag <= 31 }
					target = m.gps
				}
				tags, _, e := readDirectory(part, offset, order, accept)
				if e == nil {
					mergeMissing(target, tags, order, m.order)
				}
			}
			pos = limit
		}
	}
	walk(0, size, 0)
	return m
}
