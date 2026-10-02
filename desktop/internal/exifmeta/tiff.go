// Package exifmeta 在 Go 共用層搬移拍攝 EXIF，不重新壓縮像素。
package exifmeta

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"sort"
)

const maxMetadata = 4 << 20

var typeSize = [...]int{0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8}

type entry struct {
	tag, kind uint16
	count     uint32
	data      []byte
	wire      []byte
}
type directory map[uint16]entry
type Metadata struct {
	root, photo, gps directory
	order            binary.ByteOrder
}

func empty() Metadata                  { return Metadata{directory{}, directory{}, directory{}, binary.LittleEndian} }
func (m Metadata) Empty() bool         { return len(m.root)+len(m.photo)+len(m.gps) == 0 }
func (m Metadata) NeedsFallback() bool { return len(m.photo) == 0 }
func rootCapture(tag uint16) bool {
	switch tag {
	case 270, 271, 272, 305, 306, 315, 316, 33432, 40091, 40092, 40093, 40094, 40095:
		return true
	}
	return false
}
func photoCapture(tag uint16) bool {
	return tag >= 33434 && tag != 34665 && tag != 34853 && tag != 37500 && tag != 40965 && tag != 40962 && tag != 40963 && tag != 40961
}
func readAt(r io.ReaderAt, off int64, n int) ([]byte, error) {
	if off < 0 || n < 0 || n > maxMetadata {
		return nil, errors.New("EXIF 範圍超出限制")
	}
	b := make([]byte, n)
	_, err := r.ReadAt(b, off)
	return b, err
}
func tiffHeader(r io.ReaderAt) (binary.ByteOrder, uint32, error) {
	b, e := readAt(r, 0, 8)
	if e != nil {
		return nil, 0, e
	}
	var order binary.ByteOrder
	switch string(b[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return nil, 0, errors.New("不是 TIFF EXIF")
	}
	switch order.Uint16(b[2:4]) {
	case 42, 85, 0x4f52, 0x5352:
	default:
		return nil, 0, errors.New("不支援的 TIFF 標頭")
	}
	return order, order.Uint32(b[4:]), nil
}
func readDirectory(r io.ReaderAt, off uint32, order binary.ByteOrder, accept func(uint16) bool) (directory, uint32, error) {
	count, e := readAt(r, int64(off), 2)
	if e != nil {
		return nil, 0, e
	}
	n := int(order.Uint16(count))
	if n > 4096 {
		return nil, 0, errors.New("EXIF 欄位過多")
	}
	raw, e := readAt(r, int64(off)+2, n*12+4)
	if e != nil {
		return nil, 0, e
	}
	result := directory{}
	total := 0
	for i := 0; i < n; i++ {
		b := raw[i*12 : i*12+12]
		tag := order.Uint16(b)
		if accept != nil && !accept(tag) {
			continue
		}
		kind := order.Uint16(b[2:])
		number := order.Uint32(b[4:])
		if kind == 0 || int(kind) >= len(typeSize) {
			continue
		}
		size := uint64(number) * uint64(typeSize[kind])
		if size > maxMetadata || total+int(size) > maxMetadata {
			continue
		}
		total += int(size)
		var value []byte
		if size <= 4 {
			value = append([]byte(nil), b[8:8+int(size)]...)
		} else {
			value, e = readAt(r, int64(order.Uint32(b[8:])), int(size))
			if e != nil {
				continue
			}
		}
		result[tag] = entry{tag, kind, number, value, append([]byte(nil), b...)}
	}
	return result, order.Uint32(raw[n*12:]), nil
}
func pointer(d directory, tag uint16, order binary.ByteOrder) uint32 {
	e := d[tag]
	if e.kind == 4 && e.count == 1 && len(e.data) == 4 {
		return order.Uint32(e.data)
	}
	return 0
}
func parseTIFF(r io.ReaderAt) (Metadata, error) {
	m := empty()
	order, off, e := tiffHeader(r)
	if e != nil {
		return m, e
	}
	m.order = order
	root, _, e := readDirectory(r, off, order, func(tag uint16) bool { return rootCapture(tag) || tag == 34665 || tag == 34853 })
	if e != nil {
		return m, e
	}
	for tag, v := range root {
		if rootCapture(tag) {
			m.root[tag] = v
		}
	}
	if p := pointer(root, 34665, order); p != 0 {
		m.photo, _, _ = readDirectory(r, p, order, photoCapture)
	}
	if p := pointer(root, 34853, order); p != 0 {
		m.gps, _, _ = readDirectory(r, p, order, nil)
	}
	if m.photo == nil {
		m.photo = directory{}
	}
	if m.gps == nil {
		m.gps = directory{}
	}
	return m, nil
}
func converted(e entry, from, to binary.ByteOrder) entry {
	e.wire = nil
	e.data = append([]byte(nil), e.data...)
	if from == to || e.kind < 3 || e.kind == 6 || e.kind == 7 {
		return e
	}
	size := typeSize[e.kind]
	if e.kind == 5 || e.kind == 10 {
		size = 4
	}
	for i := 0; i+size <= len(e.data); i += size {
		for a, b := i, i+size-1; a < b; a, b = a+1, b-1 {
			e.data[a], e.data[b] = e.data[b], e.data[a]
		}
	}
	return e
}
func numeric(tag uint16, value uint32, short bool, order binary.ByteOrder) entry {
	e := entry{tag: tag, kind: 4, count: 1, data: make([]byte, 4)}
	order.PutUint32(e.data, value)
	if short {
		e.kind = 3
		e.data = make([]byte, 2)
		order.PutUint16(e.data, uint16(value))
	}
	return e
}
func merge(dst directory, src directory, from, to binary.ByteOrder) {
	for tag, e := range src {
		dst[tag] = converted(e, from, to)
	}
}

// 舊縮圖、MakerNote 和 RAW 像素結構的位址不適用於新成品，不能直接搬移。
// 光圈、快門、時間／時區、鏡頭、GPS 等欄位保留原始型別及有理數精度。
func (m Metadata) normalized(width, height int, colorSpace string, order binary.ByteOrder) Metadata {
	out := empty()
	out.order = order
	merge(out.root, m.root, m.order, order)
	merge(out.photo, m.photo, m.order, order)
	merge(out.gps, m.gps, m.order, order)
	out.root[274] = numeric(274, 1, true, order)
	out.photo[40962] = numeric(40962, uint32(width), false, order)
	out.photo[40963] = numeric(40963, uint32(height), false, order)
	color := uint32(65535)
	if colorSpace == "sRGB" {
		color = 1
	}
	out.photo[40961] = numeric(40961, color, true, order)
	return out
}

// 編碼目錄時重新配置 EXIF／GPS 指標；TIFF 成品的原始結構欄位保留既有位址。
func encodeDirectories(m Metadata, base uint32, next uint32) ([]byte, error) {
	root := directory{}
	for k, v := range m.root {
		root[k] = v
	}
	dirs := []directory{root}
	childTags := []uint16{}
	for _, child := range []struct {
		tag uint16
		d   directory
	}{{34665, m.photo}, {34853, m.gps}} {
		if len(child.d) > 0 {
			root[child.tag] = numeric(child.tag, 0, false, m.order)
			dirs = append(dirs, child.d)
			childTags = append(childTags, child.tag)
		}
	}
	offsets := make([]uint32, len(dirs))
	size := 0
	for i, d := range dirs {
		if len(d) > 4096 {
			return nil, errors.New("EXIF 欄位過多")
		}
		offsets[i] = base + uint32(size)
		size += 2 + len(d)*12 + 4
	}
	for i, tag := range childTags {
		root[tag] = numeric(tag, offsets[i+1], false, m.order)
	}
	data := make([]byte, size)
	for i, d := range dirs {
		pos := int(offsets[i] - base)
		m.order.PutUint16(data[pos:], uint16(len(d)))
		pos += 2
		tags := make([]int, 0, len(d))
		for tag := range d {
			tags = append(tags, int(tag))
		}
		sort.Ints(tags)
		for _, tag := range tags {
			e := d[uint16(tag)]
			if len(e.wire) == 12 {
				copy(data[pos:pos+12], e.wire)
				pos += 12
				continue
			}
			m.order.PutUint16(data[pos:], e.tag)
			m.order.PutUint16(data[pos+2:], e.kind)
			m.order.PutUint32(data[pos+4:], e.count)
			if len(e.data) <= 4 {
				copy(data[pos+8:pos+12], e.data)
			} else {
				if len(data)%2 != 0 {
					data = append(data, 0)
				}
				m.order.PutUint32(data[pos+8:], base+uint32(len(data)))
				data = append(data, e.data...)
			}
			pos += 12
		}
		if i == 0 {
			m.order.PutUint32(data[pos:], next)
		}
	}
	if len(data) > maxMetadata {
		return nil, errors.New("EXIF 資料過大")
	}
	return data, nil
}
func (m Metadata) encode() ([]byte, error) {
	data, e := encodeDirectories(m, 8, 0)
	if e != nil {
		return nil, e
	}
	header := []byte{'I', 'I', 42, 0, 8, 0, 0, 0}
	if m.order == binary.BigEndian {
		header = []byte{'M', 'M', 0, 42, 0, 0, 0, 8}
	}
	return append(header, data...), nil
}
func parseBytes(b []byte) (Metadata, error) { return parseTIFF(bytes.NewReader(b)) }
