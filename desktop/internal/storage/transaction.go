package storage

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// 移轉資料與收據共用一份持久化交易；中斷後於下一次啟動完成提交。
// before 保存於 recovery，供人工還原，不能只寫收據再寫資料。
type stateTransaction struct {
	Version int                        `json:"version"`
	After   map[string]json.RawMessage `json:"after"`
}

func (s *Store) Root() string { return s.root }

func atomicFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".commit-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func (s *Store) CommitStates(values map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.recoverTransaction(); err != nil {
		return err
	}
	tx := stateTransaction{Version: 1, After: map[string]json.RawMessage{}}
	before := map[string]json.RawMessage{}
	for name, value := range values {
		path, err := s.statePath(name)
		if err != nil {
			return err
		}
		data, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return err
		}
		if len(data) > 64*1024*1024 {
			return errors.New("移轉設定過大")
		}
		tx.After[name] = data
		old, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if len(old) > 0 && !json.Valid(old) {
			return fmt.Errorf("請先隔離損壞設定：%s", name)
		}
		if old == nil {
			old = []byte("null")
		}
		before[name] = old
	}
	backup, err := json.Marshal(before)
	if err != nil {
		return err
	}
	if err = atomicFile(filepath.Join(s.root, "recovery", fmt.Sprintf("migration-%d.json", time.Now().UnixNano())), backup); err != nil {
		return err
	}
	data, err := json.Marshal(tx)
	if err != nil {
		return err
	}
	if err = atomicFile(filepath.Join(s.root, "state-transaction.json"), data); err != nil {
		return err
	}
	return s.recoverTransaction()
}

func (s *Store) recoverTransaction() error {
	path := filepath.Join(s.root, "state-transaction.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var tx stateTransaction
	if json.Unmarshal(data, &tx) != nil || tx.Version != 1 || len(tx.After) == 0 {
		return errors.New("移轉交易無法還原，請保留資料目錄")
	}
	names := make([]string, 0, len(tx.After))
	for name, value := range tx.After {
		if _, err := s.statePath(name); err != nil {
			return err
		}
		if !json.Valid(value) {
			return errors.New("移轉交易內容損壞")
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		p, _ := s.statePath(name)
		if err := atomicFile(p, tx.After[name]); err != nil {
			return err
		}
	}
	return os.Remove(path)
}

// 原始位元完整保留，隔離檔案不再阻擋其他正常設定載入。
func (s *Store) QuarantineState(name string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	path, err := s.statePath(name)
	if err != nil {
		return "", err
	}
	if _, err = os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	dest := filepath.Join(s.root, "recovery", fmt.Sprintf("%d-%s", time.Now().UnixNano(), name))
	if err = os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
		return "", err
	}
	if err = os.Rename(path, dest); err != nil {
		return "", err
	}
	return dest, nil
}
