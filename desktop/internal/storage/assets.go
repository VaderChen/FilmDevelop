package storage

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
)

type PhotoSource struct {
	OriginalPath string `json:"originalPath,omitempty"`
	Path         string `json:"path"`
	Fingerprint  string `json:"fingerprint"`
}
type SubjectMask struct {
	LensCorrection    *bool  `json:"lensCorrection,omitempty"`
	SHA256            string `json:"sha256"`
	SourceFingerprint string `json:"sourceFingerprint"`
	RepairDigest      string `json:"repairDigest"`
	Width             int    `json:"width"`
	Height            int    `json:"height"`
}

// Swift FYPMASK1：小端 RGBA Float32；線性插值可能超出 0～1，保留有限權重，不裁切或重新編碼。
func ValidateMask(data []byte) (int, int, error) {
	w, h, err := maskDimensions(data, int64(len(data)))
	if err != nil {
		return 0, 0, err
	}
	if !finiteMaskWeights(data[16:]) {
		return 0, 0, errors.New("主體遮罩權重錯誤")
	}
	return w, h, nil
}

func maskDimensions(header []byte, size int64) (int, int, error) {
	if len(header) < 16 || string(header[:8]) != "FYPMASK1" {
		return 0, 0, errors.New("主體遮罩標頭錯誤")
	}
	w, h := int(binary.LittleEndian.Uint32(header[8:12])), int(binary.LittleEndian.Uint32(header[12:16]))
	if w < 1 || h < 1 || w > 4096 || h > 4096 || size != 16+int64(w)*int64(h)*16 {
		return 0, 0, errors.New("主體遮罩尺寸錯誤")
	}
	return w, h, nil
}

func finiteMaskWeights(data []byte) bool {
	for i := 0; i < len(data); i += 4 {
		// IEEE 754 的指數全為 1 才是 NaN／Inf；有限負值、次正規數與 HDR 權重均保留。
		if binary.LittleEndian.Uint32(data[i:i+4])&0x7f800000 == 0x7f800000 {
			return false
		}
	}
	return true
}

func (s *Store) MaskPath(mask *SubjectMask) string {
	if mask == nil {
		return ""
	}
	if hash, err := hex.DecodeString(mask.SHA256); err != nil || len(hash) != 32 {
		return ""
	}
	return filepath.Join(s.root, "assets", mask.SHA256+".mask.rgba")
}
func (s *Store) ImportMask(data []byte, fingerprint, repairs string) (*SubjectMask, error) {
	w, h, err := ValidateMask(data)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256(data)
	mask := &SubjectMask{SHA256: hex.EncodeToString(hash[:]), SourceFingerprint: fingerprint, RepairDigest: repairs, Width: w, Height: h}
	path := s.MaskPath(mask)
	if maskFileMatches(path, int64(len(data)), hash) {
		return mask, nil
	}
	if err := atomicFile(path, data); err != nil {
		return nil, err
	}
	return mask, nil
}

// 串流比對既有資產，避免每次匯入再配置整張遮罩；檔案變大時也只多讀一個位元組。
func maskFileMatches(path string, size int64, expected [sha256.Size]byte) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.Size() != size {
		return false
	}
	digest := sha256.New()
	n, err := io.CopyBuffer(digest, io.LimitReader(f, size+1), make([]byte, min(size, 64<<10)))
	var actual [sha256.Size]byte
	digest.Sum(actual[:0])
	return err == nil && n == size && actual == expected
}

func (s *Store) ValidateMaskAsset(mask *SubjectMask) error {
	path := s.MaskPath(mask)
	if path == "" {
		return errors.New("主體遮罩識別碼錯誤")
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.Size() > 268435472 {
		return errors.New("主體遮罩過大")
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var header [16]byte
	if _, err := io.ReadFull(f, header[:]); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return errors.New("主體遮罩標頭錯誤")
		}
		return err
	}
	w, h, err := maskDimensions(header[:], info.Size())
	if err != nil {
		return err
	}
	digest := sha256.New()
	digest.Write(header[:])
	buffer := make([]byte, min(info.Size()-16, 64<<10))
	finite := true
	for remaining := info.Size() - 16; remaining > 0; {
		size := min(int64(len(buffer)), remaining)
		part := buffer[:size]
		if _, err := io.ReadFull(f, part); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return errors.New("主體遮罩尺寸錯誤")
			}
			return err
		}
		finite = finiteMaskWeights(part) && finite
		digest.Write(part)
		remaining -= size
	}
	// 檢查讀取期間的截短／增長，尺寸驗證仍優先於權重及摘要驗證。
	if n, err := f.Read(buffer[:1]); n != 0 || err != io.EOF {
		if err != nil && err != io.EOF {
			return err
		}
		return errors.New("主體遮罩尺寸錯誤")
	}
	if !finite {
		return errors.New("主體遮罩權重錯誤")
	}
	if hex.EncodeToString(digest.Sum(nil)) != mask.SHA256 || w != mask.Width || h != mask.Height {
		return errors.New("主體遮罩完整性檢查失敗")
	}
	return nil
}

func (s *Store) PreserveFile(relative string, data []byte) error {
	if filepath.IsAbs(relative) || !filepath.IsLocal(relative) {
		return errors.New("資產路徑不符")
	}
	return atomicFile(filepath.Join(s.root, relative), data)
}
