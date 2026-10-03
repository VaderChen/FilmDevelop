package storage

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"testing"
	"time"
)

// 固定取自 8bdd679：以原有浮點檢查作為串流與位元檢查的獨立參考。
func originalValidateMask(data []byte) (int, int, error) {
	if len(data) < 16 || string(data[:8]) != "FYPMASK1" {
		return 0, 0, errors.New("主體遮罩標頭錯誤")
	}
	w, h := int(binary.LittleEndian.Uint32(data[8:12])), int(binary.LittleEndian.Uint32(data[12:16]))
	if w < 1 || h < 1 || w > 4096 || h > 4096 || len(data) != 16+w*h*16 {
		return 0, 0, errors.New("主體遮罩尺寸錯誤")
	}
	for i := 16; i < len(data); i += 4 {
		f := math.Float32frombits(binary.LittleEndian.Uint32(data[i : i+4]))
		if math.IsNaN(float64(f)) || math.IsInf(float64(f), 0) {
			return 0, 0, errors.New("主體遮罩權重錯誤")
		}
	}
	return w, h, nil
}

func TestMaskValidationMatchesOriginal(t *testing.T) {
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	s, err := New()
	if err != nil {
		t.Fatal(err)
	}
	base := maskFixture(128)
	cases := [][]byte{nil, base[:7], base[:15], base[:len(base)-1], append(bytes.Clone(base), 0), bytes.Clone(base)}
	cases[5][0] = 'X'
	for _, dimension := range []uint32{0, 4097, math.MaxUint32} {
		for _, offset := range []int{8, 12} {
			data := bytes.Clone(base)
			binary.LittleEndian.PutUint32(data[offset:], dimension)
			cases = append(cases, data)
		}
	}
	// 涵蓋正負零、次正規數、極大有限值、正負 Inf、quiet／signaling NaN 及區塊邊界。
	for _, bits := range []uint32{0, 0x80000000, 1, 0x80000001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0xff800001} {
		for _, offset := range []int{16, 16 + (64 << 10) - 4, 16 + (64 << 10), len(base) - 4} {
			data := bytes.Clone(base)
			binary.LittleEndian.PutUint32(data[offset:], bits)
			cases = append(cases, data)
		}
	}
	cases = append(cases, base)
	for i, data := range cases {
		w, h, want := originalValidateMask(data)
		gotW, gotH, got := ValidateMask(data)
		if gotW != w || gotH != h || fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("案例 %d：%d×%d %v，預期 %d×%d %v", i, gotW, gotH, got, w, h, want)
		}
		hash := sha256.Sum256(data)
		mask := &SubjectMask{SHA256: hex.EncodeToString(hash[:]), Width: w, Height: h}
		if err := atomicFile(s.MaskPath(mask), data); err != nil {
			t.Fatal(err)
		}
		if got := s.ValidateMaskAsset(mask); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("串流案例 %d：%v，預期 %v", i, got, want)
		}
	}
}

func TestMaskAssetIdentityAndRepeatedImport(t *testing.T) {
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	s, err := New()
	if err != nil {
		t.Fatal(err)
	}
	data := maskFixture(128)
	mask, err := s.ImportMask(data, "來源", "修復版本")
	if err != nil {
		t.Fatal(err)
	}
	path := s.MaskPath(mask)
	old := time.Unix(1000000000, 0)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	again, err := s.ImportMask(data, "另一來源", "另一修復")
	info, statErr := os.Stat(path)
	if err != nil || statErr != nil || again.SHA256 != mask.SHA256 || again.SourceFingerprint != "另一來源" || again.RepairDigest != "另一修復" || !info.ModTime().Equal(old) {
		t.Fatal("重複匯入未保留資產或來源中繼資料", err, statErr)
	}
	wrongDimensions := *mask
	wrongDimensions.Width++
	if err := s.ValidateMaskAsset(&wrongDimensions); err == nil || err.Error() != "主體遮罩完整性檢查失敗" {
		t.Fatal(err)
	}
	damaged := bytes.Clone(data)
	damaged[len(damaged)-1] ^= 1
	if err := os.WriteFile(path, damaged, 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.ValidateMaskAsset(mask); err == nil {
		t.Fatal("損毀資產未拒絕")
	}
	if _, err := s.ImportMask(data, "來源", "修復版本"); err != nil {
		t.Fatal(err)
	}
	if err := s.ValidateMaskAsset(mask); err != nil {
		t.Fatal("重新匯入未修復資產", err)
	}
	if err := os.Truncate(path, 268435473); err != nil {
		t.Fatal(err)
	}
	if err := s.ValidateMaskAsset(mask); err == nil || err.Error() != "主體遮罩過大" {
		t.Fatal(err)
	}
}
