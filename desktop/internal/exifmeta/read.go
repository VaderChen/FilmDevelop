package exifmeta

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"os"
)

// Read 以位址讀取 TIFF／RAW 目錄；其他容器只搜尋有界的檔頭與檔尾。
// 每個候選都須通過 TIFF 目錄及資料範圍驗證，不解碼或改動照片像素。
func Read(ctx context.Context, path string) (Metadata, error) {
	f, err := os.Open(path)
	if err != nil {
		return empty(), err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return empty(), err
	}
	if m, e := parseTIFF(f); e == nil && !m.Empty() {
		return m, nil
	}
	if header, e := readAt(f, 0, 8); e == nil && string(header[4:]) == "ftyp" {
		if m := readBMFF(ctx, f, info.Size()); !m.Empty() {
			return m, ctx.Err()
		}
	}
	result := empty()
	const window = int64(8 << 20)
	ranges := [][2]int64{{0, min(info.Size(), window)}}
	if info.Size() > window {
		ranges = append(ranges, [2]int64{max(window, info.Size()-window), info.Size()})
	}
	signatures := [][]byte{{'I', 'I', 42, 0}, {'M', 'M', 0, 42}}
	candidates := 0
	for _, span := range ranges {
		for pos := span[0]; pos < span[1]; pos += 64 << 10 {
			if err := ctx.Err(); err != nil {
				return result, err
			}
			blockEnd := min(span[1], pos+(64<<10)+3)
			b, e := readAt(f, pos, int(blockEnd-pos))
			if e != nil {
				return result, e
			}
			// 保持檔案順序：主 EXIF 優先，後面的內嵌預覽只補齊缺少的拍攝欄位。
			for at := 0; at+4 <= len(b); at++ {
				if !bytes.Equal(b[at:at+4], signatures[0]) && !bytes.Equal(b[at:at+4], signatures[1]) {
					continue
				}
				candidates++
				if candidates > 128 {
					return result, nil
				}
				reader := io.NewSectionReader(f, pos+int64(at), info.Size()-pos-int64(at))
				m, e := parseTIFF(reader)
				if e != nil {
					continue
				}
				mergeMissing(result.root, m.root, m.order, result.order)
				mergeMissing(result.photo, m.photo, m.order, result.order)
				mergeMissing(result.gps, m.gps, m.order, result.order)
			}
		}
	}
	return result, nil
}
func mergeMissing(dst, src directory, from, to binary.ByteOrder) {
	for tag, e := range src {
		if _, ok := dst[tag]; !ok {
			dst[tag] = converted(e, from, to)
		}
	}
}
