package exifmeta

import (
	"bytes"
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestBMFFUsesContainerBoundaries(t *testing.T) {
	source, err := Read(context.Background(), "testdata/source.jpg")
	if err != nil {
		t.Fatal(err)
	}
	box := func(kind string, payload []byte) []byte {
		b := make([]byte, 8)
		binary.BigEndian.PutUint32(b, uint32(len(payload)+8))
		copy(b[4:], kind)
		return append(b, payload...)
	}
	part := func(tags directory) []byte {
		m := empty()
		m.root = tags
		m.order = source.order
		b, e := m.encode()
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	decoy := directory{}
	merge(decoy, source.photo, source.order, source.order)
	d := decoy[36867]
	d.data = []byte("1999:01:01 00:00:00\x00")
	decoy[36867] = d
	// free 內的有效 TIFF 備份不可蓋過真正 CMT2 的拍攝資料。
	payload := append(box("free", part(decoy)), box("CMT1", part(source.root))...)
	payload = append(payload, box("CMT2", part(source.photo))...)
	payload = append(payload, box("CMT4", part(source.gps))...)
	payload = box("uuid", append(make([]byte, 16), payload...))
	// 同時驗證 64 位元 BMFF 區塊長度。
	moov := make([]byte, 16)
	binary.BigEndian.PutUint32(moov, 1)
	copy(moov[4:], "moov")
	binary.BigEndian.PutUint64(moov[8:], uint64(16+len(payload)))
	data := append(box("ftyp", []byte("crx \x00\x00\x00\x00")), append(moov, payload...)...)
	path := filepath.Join(t.TempDir(), "source.cr3")
	if e := os.WriteFile(path, data, 0600); e != nil {
		t.Fatal(e)
	}
	got, e := Read(context.Background(), path)
	if e != nil {
		t.Fatal(e)
	}
	for _, tag := range []uint16{36867, 33434, 34855, 42036} {
		if !bytes.Equal(got.photo[tag].data, converted(source.photo[tag], source.order, got.order).data) {
			t.Fatalf("拍攝欄位 %d 被錯誤區塊蓋過", tag)
		}
	}
	if !bytes.Equal(got.gps[2].data, converted(source.gps[2], source.order, got.order).data) {
		t.Fatal("GPS 遺失")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := Read(ctx, path); e == nil {
		t.Fatal("忽略取消")
	}
}
