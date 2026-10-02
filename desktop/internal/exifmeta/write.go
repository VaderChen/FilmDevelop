package exifmeta

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
)

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r contextReader) Read(b []byte) (int, error) {
	if e := r.ctx.Err(); e != nil {
		return 0, e
	}
	return r.r.Read(b)
}
func copyN(ctx context.Context, w io.Writer, r io.Reader, n int64) error {
	_, e := io.CopyN(w, contextReader{ctx, r}, n)
	return e
}
func writeAll(w io.Writer, parts ...[]byte) error {
	for _, b := range parts {
		if _, e := w.Write(b); e != nil {
			return e
		}
	}
	return nil
}

// Write 只處理原生引擎的暫存成品；成功後才替換暫存檔，發布仍由 engine 負責。
func Write(ctx context.Context, path, format, colorSpace string, width, height int, m Metadata) error {
	if m.Empty() {
		return nil
	}
	if width < 1 || height < 1 {
		return errors.New("EXIF 缺少正確的輸出尺寸")
	}
	input, e := os.Open(path)
	if e != nil {
		return e
	}
	defer input.Close()
	output, e := os.CreateTemp(filepath.Dir(path), ".exif-*")
	if e != nil {
		return e
	}
	defer os.Remove(output.Name())
	defer output.Close()
	normalized := m.normalized(width, height, colorSpace, binary.LittleEndian)
	raw, e := normalized.encode()
	if e != nil {
		return e
	}
	switch format {
	case "jpeg":
		e = writeJPEG(ctx, input, output, raw)
	case "png":
		e = writePNG(ctx, input, output, raw)
	case "webp":
		e = writeWebP(ctx, input, output, raw, width, height)
	case "tiff":
		e = writeTIFF(ctx, input, output, m, width, height, colorSpace)
	default:
		e = errors.New("此格式不支援寫入 EXIF")
	}
	if e != nil {
		return e
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	if e = output.Sync(); e != nil {
		return e
	}
	if e = output.Close(); e != nil {
		return e
	}
	if e = input.Close(); e != nil {
		return e
	}
	return os.Rename(output.Name(), path)
}
func writeJPEG(ctx context.Context, r io.Reader, w io.Writer, exif []byte) error {
	if len(exif)+8 > 65535 {
		return errors.New("EXIF 超過 JPEG 可容納的大小")
	}
	var h [4]byte
	if _, e := io.ReadFull(r, h[:2]); e != nil {
		return e
	}
	if !bytes.Equal(h[:2], []byte{255, 216}) {
		return errors.New("JPEG 標頭不符")
	}
	if e := writeAll(w, h[:2]); e != nil {
		return e
	}
	payload := append([]byte("Exif\x00\x00"), exif...)
	header := []byte{255, 225, 0, 0}
	binary.BigEndian.PutUint16(header[2:], uint16(len(payload)+2))
	inserted := false
	for {
		if _, e := io.ReadFull(r, h[:2]); e != nil {
			return e
		}
		if h[0] != 255 {
			return errors.New("JPEG 區塊不符")
		}
		for h[1] == 255 {
			if _, e := io.ReadFull(r, h[1:2]); e != nil {
				return e
			}
		}
		if h[1] != 224 && !inserted {
			if e := writeAll(w, header, payload); e != nil {
				return e
			}
			inserted = true
		}
		if h[1] == 218 || h[1] == 217 {
			if e := writeAll(w, h[:2]); e != nil {
				return e
			}
			_, e := io.Copy(w, contextReader{ctx, r})
			return e
		}
		if _, e := io.ReadFull(r, h[2:]); e != nil {
			return e
		}
		n := int(binary.BigEndian.Uint16(h[2:])) - 2
		if n < 0 {
			return errors.New("JPEG 區塊長度不符")
		}
		b := make([]byte, n)
		if _, e := io.ReadFull(r, b); e != nil {
			return e
		}
		if h[1] == 225 && bytes.HasPrefix(b, []byte("Exif\x00\x00")) {
			continue
		}
		if e := writeAll(w, h[:], b); e != nil {
			return e
		}
	}
}
func pngChunk(w io.Writer, kind string, data []byte) error {
	h := make([]byte, 8)
	binary.BigEndian.PutUint32(h, uint32(len(data)))
	copy(h[4:], kind)
	sum := crc32.NewIEEE()
	sum.Write(h[4:])
	sum.Write(data)
	tail := make([]byte, 4)
	binary.BigEndian.PutUint32(tail, sum.Sum32())
	return writeAll(w, h, data, tail)
}
func writePNG(ctx context.Context, r io.ReadSeeker, w io.Writer, exif []byte) error {
	var h [8]byte
	if _, e := io.ReadFull(r, h[:]); e != nil {
		return e
	}
	if string(h[:]) != "\x89PNG\r\n\x1a\n" {
		return errors.New("PNG 標頭不符")
	}
	if e := writeAll(w, h[:]); e != nil {
		return e
	}
	for {
		if _, e := io.ReadFull(r, h[:]); e != nil {
			return e
		}
		size := int64(binary.BigEndian.Uint32(h[:4]))
		kind := string(h[4:])
		if size > 0x7fffffff {
			return errors.New("PNG 區塊過大")
		}
		if kind == "eXIf" {
			if _, e := r.Seek(size+4, io.SeekCurrent); e != nil {
				return e
			}
			continue
		}
		if e := writeAll(w, h[:]); e != nil {
			return e
		}
		if e := copyN(ctx, w, r, size+4); e != nil {
			return e
		}
		if kind == "IHDR" {
			if e := pngChunk(w, "eXIf", exif); e != nil {
				return e
			}
		}
		if kind == "IEND" {
			return nil
		}
	}
}
func riffChunk(w io.Writer, kind string, data []byte) error {
	h := make([]byte, 8)
	copy(h, kind)
	binary.LittleEndian.PutUint32(h[4:], uint32(len(data)))
	if e := writeAll(w, h, data); e != nil {
		return e
	}
	if len(data)%2 != 0 {
		return writeAll(w, []byte{0})
	}
	return nil
}
func writeWebP(ctx context.Context, r *os.File, w *os.File, exif []byte, width, height int) error {
	h, e := readAt(r, 0, 12)
	if e != nil {
		return e
	}
	if string(h[:4]) != "RIFF" || string(h[8:]) != "WEBP" {
		return errors.New("WebP 標頭不符")
	}
	end := int64(binary.LittleEndian.Uint32(h[4:])) + 8
	flags := byte(8)
	hasExtended := false
	for pos := int64(12); pos+8 <= end; {
		b, e := readAt(r, pos, 8)
		if e != nil {
			return e
		}
		n := int64(binary.LittleEndian.Uint32(b[4:]))
		if n > end-pos-8 {
			return errors.New("WebP 區塊不符")
		}
		switch string(b[:4]) {
		case "VP8X":
			hasExtended = true
		case "ICCP":
			flags |= 32
		case "XMP ":
			flags |= 4
		case "ALPH":
			flags |= 16
		case "ANIM":
			flags |= 2
		case "VP8L":
			if n >= 5 {
				p, e := readAt(r, pos+8, 5)
				if e != nil {
					return e
				}
				if p[4]&16 != 0 {
					flags |= 16
				}
			}
		}
		pos += 8 + n + n%2
	}
	if e = writeAll(w, h); e != nil {
		return e
	}
	if !hasExtended {
		if width > 1<<24 || height > 1<<24 {
			return errors.New("WebP 尺寸不符")
		}
		v := make([]byte, 10)
		v[0] = flags
		for i := 0; i < 3; i++ {
			v[4+i] = byte((width - 1) >> (8 * i))
			v[7+i] = byte((height - 1) >> (8 * i))
		}
		if e = riffChunk(w, "VP8X", v); e != nil {
			return e
		}
	}
	inserted := false
	for pos := int64(12); pos+8 <= end; {
		b, e := readAt(r, pos, 8)
		if e != nil {
			return e
		}
		n := int64(binary.LittleEndian.Uint32(b[4:]))
		kind := string(b[:4])
		if kind == "XMP " && !inserted {
			if e = riffChunk(w, "EXIF", exif); e != nil {
				return e
			}
			inserted = true
		}
		if kind == "VP8X" {
			if n != 10 {
				return errors.New("WebP VP8X 長度不符")
			}
			v, e := readAt(r, pos+8, 10)
			if e != nil {
				return e
			}
			v[0] |= 8
			if e = riffChunk(w, kind, v); e != nil {
				return e
			}
		} else if kind != "EXIF" {
			if _, e = r.Seek(pos, io.SeekStart); e != nil {
				return e
			}
			if e = copyN(ctx, w, r, 8+n+n%2); e != nil {
				return e
			}
		}
		pos += 8 + n + n%2
	}
	if !inserted {
		if e = riffChunk(w, "EXIF", exif); e != nil {
			return e
		}
	}
	length, e := w.Seek(0, io.SeekCurrent)
	if e != nil {
		return e
	}
	if length-8 > 0xffffffff {
		return errors.New("WebP 成品過大")
	}
	binary.LittleEndian.PutUint32(h[:4], uint32(length-8))
	_, e = w.WriteAt(h[:4], 4)
	return e
}
func writeTIFF(ctx context.Context, r *os.File, w *os.File, m Metadata, width, height int, colorSpace string) error {
	order, offset, e := tiffHeader(r)
	if e != nil {
		return e
	}
	info, e := r.Stat()
	if e != nil {
		return e
	}
	if info.Size() > 0xffffffff-maxMetadata {
		return errors.New("TIFF 成品超過 32 位元位址")
	}
	b, e := readAt(r, int64(offset), 2)
	if e != nil {
		return e
	}
	n := int(order.Uint16(b))
	if n > 4096 {
		return errors.New("TIFF 目錄過大")
	}
	raw, e := readAt(r, int64(offset)+2, n*12+4)
	if e != nil {
		return e
	}
	normalized := m.normalized(width, height, colorSpace, order)
	for i := 0; i < n; i++ {
		wire := raw[i*12 : i*12+12]
		tag := order.Uint16(wire)
		if tag == 34665 || tag == 34853 {
			continue
		}
		if _, ok := normalized.root[tag]; !ok {
			normalized.root[tag] = entry{tag: tag, wire: append([]byte(nil), wire...)}
		}
	}
	base := uint32(info.Size())
	if base%2 != 0 {
		base++
	}
	data, e := encodeDirectories(normalized, base, order.Uint32(raw[n*12:]))
	if e != nil {
		return e
	}
	if _, e = r.Seek(0, io.SeekStart); e != nil {
		return e
	}
	if e = copyN(ctx, w, r, info.Size()); e != nil {
		return e
	}
	if int64(base) > info.Size() {
		if e = writeAll(w, []byte{0}); e != nil {
			return e
		}
	}
	if e = writeAll(w, data); e != nil {
		return e
	}
	p := make([]byte, 4)
	order.PutUint32(p, base)
	_, e = w.WriteAt(p, 4)
	return e
}
