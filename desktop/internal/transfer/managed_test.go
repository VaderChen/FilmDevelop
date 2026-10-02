package transfer

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestManagedModelRecovery(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "model.onnx")
	destination := filepath.Join(root, "models")
	valid := []byte("valid model content")
	_ = os.WriteFile(source, valid, 0600)
	files := []File{{Path: "model.onnx", Source: source, Size: int64(len(valid)), SHA256: fmt.Sprintf("%x", sha256.Sum256(valid))}}
	if err := EnsureManagedDirectory(context.Background(), destination, files, nil); err != nil {
		t.Fatal(err)
	}
	// 已驗證的快取不需來源仍可使用；相同大小的損壞不能誤認為有效。
	_ = os.Remove(source)
	if err := EnsureManagedDirectory(context.Background(), destination, files, nil); err != nil {
		t.Fatal(err)
	}
	corrupt := []byte("wrong model content")
	if len(corrupt) != len(valid) {
		t.Fatal("測試長度不符")
	}
	_ = os.WriteFile(filepath.Join(destination, "model.onnx"), corrupt, 0600)
	if err := EnsureManagedDirectory(context.Background(), destination, files, nil); err == nil {
		t.Fatal("缺少下載來源卻成功")
	}
	old, _ := os.ReadFile(filepath.Join(destination, "model.onnx"))
	if string(old) != string(corrupt) {
		t.Fatal("失敗沒有還原原目錄")
	}
	_ = os.WriteFile(filepath.Join(destination, "notes.txt"), []byte("保留"), 0600)
	_ = os.WriteFile(source, valid, 0600)
	if err := EnsureManagedDirectory(context.Background(), destination, files, nil); err != nil {
		t.Fatal(err)
	}
	current, _ := os.ReadFile(filepath.Join(destination, "model.onnx"))
	if string(current) != string(valid) {
		t.Fatal("沒有完成替換")
	}
	backups, _ := filepath.Glob(filepath.Join(root, ".filmdevelop-invalid-model-*", "notes.txt"))
	if len(backups) != 1 {
		t.Fatal("額外檔案未保留")
	}
}
