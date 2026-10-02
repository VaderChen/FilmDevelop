package storage

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math"
	"os"
	"path/filepath"
)

type PhotoSource struct {
	OriginalPath string `json:"originalPath,omitempty"`
	Path         string `json:"path"`
	Fingerprint  string `json:"fingerprint"`
}
type SubjectMask struct {
	SHA256            string `json:"sha256"`
	SourceFingerprint string `json:"sourceFingerprint"`
	RepairDigest      string `json:"repairDigest"`
	Width             int    `json:"width"`
	Height            int    `json:"height"`
}

// Swift FYPMASK1：小端 RGBA Float32；線性插值可能超出 0～1，保留有限權重，不裁切或重新編碼。
func ValidateMask(data []byte) (int, int, error) {
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
	mask := &SubjectMask{hex.EncodeToString(hash[:]), fingerprint, repairs, w, h}
	path := s.MaskPath(mask)
	if old, err := os.ReadFile(path); err == nil && sha256.Sum256(old) == hash {
		return mask, nil
	}
	if err := atomicFile(path, data); err != nil {
		return nil, err
	}
	return mask, nil
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
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	w, h, err := ValidateMask(data)
	if err != nil {
		return err
	}
	hash := sha256.Sum256(data)
	if hex.EncodeToString(hash[:]) != mask.SHA256 || w != mask.Width || h != mask.Height {
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
