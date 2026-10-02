// Package storage 以內容雜湊識別照片，保存完整原生配方，不轉換任何像素參數。
package storage

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

type Document struct {
	Fresh               bool                       `json:"-"`
	Source              *PhotoSource               `json:"source,omitempty"`
	SubjectMask         *SubjectMask               `json:"subjectMask,omitempty"`
	Manual              *ManualAdjustments         `json:"manualAdjustments,omitempty"`
	SharedRepairPatches json.RawMessage            `json:"sharedRepairPatches,omitempty"`
	CustomID            string                     `json:"customFilmID,omitempty"`
	CustomBase          *contract.Recipe           `json:"customBase,omitempty"`
	Version             int                        `json:"version"`
	Selected            string                     `json:"selected"`
	Recipes             map[string]contract.Recipe `json:"recipes"`
}
type ManualAdjustments struct {
	PrintControls      []string `json:"printControls"`
	HasCompleteHistory bool     `json:"hasCompleteHistory"`
}
type Store struct {
	root string
	mu   sync.Mutex
}

// LoadState／SaveState 保存跨平台宿主設定，與依內容識別的照片配方分開。
func (s *Store) statePath(name string) (string, error) {
	if name == "" || filepath.Base(name) != name || strings.ContainsAny(name, "/\\") || !strings.HasSuffix(name, ".json") {
		return "", errors.New("設定檔名稱不符")
	}
	return filepath.Join(s.root, "state", name), nil
}
func (s *Store) LoadState(name string, value any) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.recoverTransaction(); err != nil {
		return false, err
	}
	path, err := s.statePath(name)
	if err != nil {
		return false, err
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, contract.MaxMessageBytes+1))
	if err != nil {
		return false, err
	}
	if len(data) > contract.MaxMessageBytes {
		return false, errors.New("設定檔超過大小限制")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(value); err != nil {
		return false, err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return false, errors.New("設定檔包含多餘資料")
	}
	return true, nil
}
func (s *Store) SaveState(name string, value any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.recoverTransaction(); err != nil {
		return err
	}
	path, err := s.statePath(name)
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if len(data) > contract.MaxMessageBytes {
		return errors.New("設定檔超過大小限制")
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

// DataDirectory 集中解析資料位置；Windows 使用固定名稱，macOS 保留既有 Go 宿主資料。
func DataDirectory() (string, error) {
	root := os.Getenv("FILMDEVELOP_DATA_DIR")
	if root == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return "", err
		}
		name := "FilmDevelop-GoDevelopment"
		if runtime.GOOS == "windows" {
			name = "FilmDevelop"
		}
		root = filepath.Join(base, name)
	}
	return root, nil
}

func New() (*Store, error) {
	root, err := DataDirectory()
	if err != nil {
		return nil, err
	}
	s := &Store{root: root}
	if err := s.recoverTransaction(); err != nil {
		return nil, err
	}
	return s, nil
}

// PhotoKey 以路徑＋內容識別碼隔離複本。Go 傳入裸雜湊；舊 Swift 的識別碼含 sha256: 前綴。
func PhotoKey(path, fingerprint string) string {
	canonical, err := filepath.EvalSymlinks(path)
	if err == nil {
		path = canonical
	}
	path, _ = filepath.Abs(path)
	digest := sha256.Sum256([]byte(filepath.Clean(path) + "\n" + fingerprint))
	return hex.EncodeToString(digest[:])
}

func Fingerprint(ctx context.Context, path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	before, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !before.Mode().IsRegular() {
		return "", errors.New("來源必須是一般影像檔案")
	}
	hash := sha256.New()
	buffer := make([]byte, 1024*1024)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, err := file.Read(buffer)
		if n > 0 {
			_, _ = hash.Write(buffer[:n])
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
	}
	after, err := file.Stat()
	if err != nil {
		return "", err
	}
	if before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return "", errors.New("來源照片在讀取時變更，請重試")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func (s *Store) path(key string) (string, error) {
	decoded, err := hex.DecodeString(key)
	if err != nil || len(decoded) != 32 {
		return "", errors.New("照片識別碼格式錯誤")
	}
	return filepath.Join(s.root, "photos", key+".json"), nil
}
func (s *Store) Load(key string) (*Document, error) {
	path, err := s.path(key)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, contract.MaxMessageBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > contract.MaxMessageBytes {
		return nil, errors.New("調整紀錄超過大小限制")
	}
	var document Document
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("無法讀取調整紀錄，原檔已保留：%w", err)
	}
	if decoder.Decode(new(any)) != io.EOF || document.Version != 1 || document.Selected == "" || document.Recipes == nil {
		return nil, errors.New("調整紀錄版本或格式不符，原檔已保留")
	}
	if len(document.SharedRepairPatches) > 0 {
		for id, recipe := range document.Recipes {
			if string(recipe.RepairPatches) != "[]" {
				return nil, errors.New("共用修復紀錄與底片紀錄衝突")
			}
			recipe.RepairPatches = document.SharedRepairPatches
			document.Recipes[id] = recipe
		}
		document.SharedRepairPatches = nil
	}
	return &document, nil
}
func (s *Store) Save(key string, document Document) error {
	path, err := s.path(key)
	if err != nil {
		return err
	}
	if _, err := s.Load(key); err != nil {
		return err
	}
	// 修復是照片層級資料；相同補片不隨每款底片重複寫入。
	var common json.RawMessage
	consistent := len(document.Recipes) > 0
	for _, recipe := range document.Recipes {
		if common == nil {
			common = recipe.RepairPatches
		}
		if !bytes.Equal(common, recipe.RepairPatches) {
			consistent = false
		}
	}
	if consistent && len(common) > 2 {
		document.SharedRepairPatches = common
		document.Recipes = cloneRecipeMap(document.Recipes)
		for id, recipe := range document.Recipes {
			recipe.RepairPatches = json.RawMessage(`[]`)
			document.Recipes[id] = recipe
		}
	}
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	if len(data) > contract.MaxMessageBytes {
		return errors.New("調整紀錄超過大小限制")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".recipe-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err = temp.Write(data); err == nil {
		err = temp.Sync()
	}
	closeErr := temp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temp.Name(), path)
}

func cloneRecipeMap(source map[string]contract.Recipe) map[string]contract.Recipe {
	result := make(map[string]contract.Recipe, len(source))
	for id, recipe := range source {
		result[id] = recipe
	}
	return result
}
