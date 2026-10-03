package engine

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestPublishUnsupportedFilesystem(t *testing.T) {
	for _, cause := range []error{unix.ENOTSUP, unix.ENOSYS, unix.EINVAL} {
		t.Run(cause.Error(), func(t *testing.T) {
			dir := t.TempDir()
			source, target := filepath.Join(dir, "完整成品.jpg"), filepath.Join(dir, "輸出.jpg")
			content := []byte("JPEG 成品已完整編碼")
			if err := os.WriteFile(source, content, 0600); err != nil {
				t.Fatal(err)
			}
			unsupported := func(string, string, uint32) error { return cause }
			if err := publishDarwin(source, target, unsupported); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(target)
			if err != nil || string(data) != string(content) {
				t.Fatal("相容發布遺失成品", err)
			}
			if err = publishDarwin(source, target, unsupported); !errors.Is(err, os.ErrExist) {
				t.Fatal("相容發布不得覆寫", err)
			}
		})
	}
	dir := t.TempDir()
	if err := publishDarwin("unused", filepath.Join(dir, "target"), func(string, string, uint32) error { return unix.EACCES }); !errors.Is(err, unix.EACCES) {
		t.Fatal("不得略過權限錯誤", err)
	}
}
