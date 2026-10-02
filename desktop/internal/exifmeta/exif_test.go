package exifmeta

import (
	"bytes"
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, e := os.ReadFile(filepath.Join("testdata", name))
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func TestCaptureExifWithoutChangingImageData(t *testing.T) {
	source, e := Read(context.Background(), "testdata/source.jpg")
	if e != nil || source.Empty() {
		t.Fatal(e)
	}
	for _, f := range []struct{ name, format string }{{"output.jpg", "jpeg"}, {"output.png", "png"}, {"output.tif", "tiff"}, {"lzw.tif", "tiff"}, {"output.webp", "webp"}, {"bare.webp", "webp"}, {"alpha.webp", "webp"}, {"sixteen.png", "png"}, {"sixteen.tif", "tiff"}} {
		t.Run(f.name, func(t *testing.T) {
			before := fixture(t, f.name)
			path := filepath.Join(t.TempDir(), f.name)
			if e := os.WriteFile(path, before, 0600); e != nil {
				t.Fatal(e)
			}
			if e := Write(context.Background(), path, f.format, "displayP3", 7, 5, source); e != nil {
				t.Fatal(e)
			}
			after, e := os.ReadFile(path)
			if e != nil {
				t.Fatal(e)
			}
			got, e := Read(context.Background(), path)
			if e != nil {
				t.Fatal(e)
			}
			if !bytes.Equal(got.root[271].data, source.root[271].data) || !bytes.Equal(got.photo[36867].data, source.photo[36867].data) || !bytes.Equal(got.photo[36881].data, source.photo[36881].data) || !bytes.Equal(got.photo[33434].data, converted(source.photo[33434], source.order, got.order).data) || !bytes.Equal(got.gps[2].data, converted(source.gps[2], source.order, got.order).data) {
				t.Fatal("原始拍攝 EXIF／GPS 遺失")
			}
			order, off, e := tiffHeader(bytes.NewReader(extractBlock(t, after, f.format)))
			if e != nil {
				t.Fatal(e)
			}
			root, _, e := readDirectory(bytes.NewReader(extractBlock(t, after, f.format)), off, order, nil)
			if e != nil {
				t.Fatal(e)
			}
			if order.Uint16(root[274].data) != 1 {
				t.Fatal("沿用舊方向")
			}
			photo, _, e := readDirectory(bytes.NewReader(extractBlock(t, after, f.format)), pointer(root, 34665, order), order, nil)
			if e != nil {
				t.Fatal(e)
			}
			if order.Uint32(photo[40962].data) != 7 || order.Uint32(photo[40963].data) != 5 || order.Uint16(photo[40961].data) != 65535 {
				t.Fatal("未更新尺寸或色彩空間")
			}
			if _, ok := photo[37500]; ok {
				t.Fatal("搬移不可重定位的 MakerNote")
			}
			if f.format == "tiff" {
				if !bytes.Equal(before[:4], after[:4]) || !bytes.Equal(before[8:], after[8:len(before)]) {
					t.Fatal("TIFF 原有影像資料被更動")
				}
			} else if !bytes.Equal(pixelPayload(t, before, f.format), pixelPayload(t, after, f.format)) {
				t.Fatal("影像壓縮資料被更動")
			}
			// 再次寫入須取代既有 EXIF，且保持可讀。
			if e := Write(context.Background(), path, f.format, "sRGB", 7, 5, source); e != nil {
				t.Fatal(e)
			}
		})
	}
}
func extractBlock(t *testing.T, b []byte, format string) []byte {
	t.Helper()
	switch format {
	case "tiff":
		return b
	case "jpeg":
		p := bytes.Index(b, []byte("Exif\x00\x00"))
		if p < 0 {
			t.Fatal("缺少 APP1 EXIF")
		}
		n := int(binary.BigEndian.Uint16(b[p-2 : p]))
		return b[p+6 : p-2+n]
	case "png":
		for p := 8; p+12 <= len(b); {
			n := int(binary.BigEndian.Uint32(b[p : p+4]))
			if string(b[p+4:p+8]) == "eXIf" {
				return b[p+8 : p+8+n]
			}
			p += 12 + n
		}
	case "webp":
		for p := 12; p+8 <= len(b); {
			n := int(binary.LittleEndian.Uint32(b[p+4 : p+8]))
			if string(b[p:p+4]) == "EXIF" {
				return b[p+8 : p+8+n]
			}
			p += 8 + n + n%2
		}
	}
	t.Fatal("沒有 EXIF 區塊")
	return nil
}
func pixelPayload(t *testing.T, b []byte, format string) []byte {
	t.Helper()
	var out []byte
	switch format {
	case "jpeg":
		p := bytes.Index(b, []byte{255, 218})
		if p < 0 {
			t.Fatal("缺少 SOS")
		}
		return b[p:]
	case "png":
		for p := 8; p+12 <= len(b); {
			n := int(binary.BigEndian.Uint32(b[p : p+4]))
			if string(b[p+4:p+8]) != "eXIf" {
				out = append(out, b[p:p+12+n]...)
			}
			p += 12 + n
		}
	case "webp":
		for p := 12; p+8 <= len(b); {
			n := int(binary.LittleEndian.Uint32(b[p+4 : p+8]))
			kind := string(b[p : p+4])
			if kind != "EXIF" && kind != "VP8X" {
				out = append(out, b[p:p+8+n+n%2]...)
			}
			p += 8 + n + n%2
		}
	}
	return out
}
func TestMalformedExifAndCancellation(t *testing.T) {
	for _, b := range [][]byte{nil, []byte("II*\x00\xff\xff\xff\xff"), []byte("MM\x00*\x00\x00\x00\x08\xff\xff")} {
		path := filepath.Join(t.TempDir(), "invalid")
		os.WriteFile(path, b, 0600)
		if _, e := Read(context.Background(), path); e != nil {
			t.Fatal(e)
		}
	}
	path := filepath.Join(t.TempDir(), "photo.png")
	before := fixture(t, "output.png")
	os.WriteFile(path, before, 0600)
	m, _ := Read(context.Background(), "testdata/source.jpg")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if e := Write(ctx, path, "png", "sRGB", 7, 5, m); e == nil {
		t.Fatal("取消失效")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("取消破壞成品")
	}
}
