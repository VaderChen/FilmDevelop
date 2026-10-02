package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestTransferPublishesOnlyValidatedCompleteFiles(t *testing.T) {
	data := []byte("完整模型內容")
	sum := sha256.Sum256(data)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(data) }))
	defer server.Close()
	files := []File{{Path: "model.bin", URL: server.URL, Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}}
	root := t.TempDir()
	dest := filepath.Join(root, "installed")
	if err := InstallDirectory(context.Background(), dest, files, func(stage string) error {
		bytes, err := os.ReadFile(filepath.Join(stage, "model.bin"))
		if err == nil && string(bytes) != string(data) {
			t.Fatal("內容不符")
		}
		return err
	}, nil); err != nil {
		t.Fatal(err)
	}
	if err := InstallDirectory(context.Background(), dest, files, nil, nil); err == nil {
		t.Fatal("覆蓋既有模型")
	}
	files[0].SHA256 = "invalid"
	bad := filepath.Join(root, "bad")
	if err := InstallDirectory(context.Background(), bad, files, nil, nil); err == nil {
		t.Fatal("未驗證雜湊")
	}
	if _, err := os.Stat(bad); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("失敗仍發布模型")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := InstallDirectory(ctx, filepath.Join(root, "cancel"), files, nil, nil); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if err := InstallDirectory(context.Background(), filepath.Join(root, "path"), []File{{Path: "../escape", URL: server.URL}}, nil, nil); err == nil {
		t.Fatal("允許離開安裝目錄")
	}
	files[0].SHA256 = hex.EncodeToString(sum[:])
	race := filepath.Join(root, "race")
	if err := InstallDirectory(context.Background(), race, files, func(string) error { return os.Mkdir(race, 0700) }, nil); err == nil {
		t.Fatal("發布覆蓋並行建立的目錄")
	}
}
