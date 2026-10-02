package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// 模擬 Windows 引擎以路徑與 File ID 辨認來源，經過真正的 Go Render 入口。
func TestPreviewSourceWorker(t *testing.T) {
	if os.Getenv("FILMDEVELOP_TEST_SOURCE") != "1" {
		return
	}
	decoder := json.NewDecoder(os.Stdin)
	encoder := json.NewEncoder(os.Stdout)
	var previous os.FileInfo
	var previousPath string
	for {
		var request contract.Request
		if decoder.Decode(&request) != nil {
			os.Exit(0)
		}
		var job contract.RenderJob
		if json.Unmarshal(request.Payload, &job) != nil {
			os.Exit(2)
		}
		info, err := os.Stat(job.Input.Path)
		if err != nil {
			os.Exit(3)
		}
		hit := previous != nil && previousPath == job.Input.Path && os.SameFile(previous, info)
		previous, previousPath = info, job.Input.Path
		_ = encoder.Encode(contract.Response{Version: 1, ID: request.ID, Kind: "progress", Payload: json.RawMessage("0.2")})
		if job.PreviewMaxPixel == 123 {
			time.Sleep(150 * time.Millisecond)
		}
		data, err := os.ReadFile(job.Input.Path)
		if err != nil || os.WriteFile(job.Output.Path, data, 0600) != nil {
			os.Exit(4)
		}
		payload, _ := json.Marshal(map[string]any{"sourceCacheHit": hit, "source": job.Input.Path})
		_ = encoder.Encode(contract.Response{Version: 1, ID: request.ID, Kind: "result", Payload: payload})
	}
}

func sourceHelper(t *testing.T) *Client {
	t.Helper()
	c := New(os.Args[0])
	c.command = func(ctx context.Context) *exec.Cmd {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPreviewSourceWorker$")
		cmd.Env = append(os.Environ(), "FILMDEVELOP_TEST_SOURCE=1")
		return cmd
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestPreviewSourceIdentityAndInvalidation(t *testing.T) {
	c, dir := sourceHelper(t), t.TempDir()
	input := filepath.Join(dir, "source.bmp")
	if err := os.WriteFile(input, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(input)
	var paths []string
	for i, expectedHit := range []bool{false, true, false, true, false} {
		if i == 2 {
			// 檔案大小及時間完全相同也必須失效，不能僅信任 stat。
			if err := os.WriteFile(input, []byte("modified"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.Chtimes(input, before.ModTime(), before.ModTime()); err != nil {
				t.Fatal(err)
			}
		}
		if i == 4 {
			input = filepath.Join(dir, "source.jpeg")
			if err := os.WriteFile(input, []byte("modified"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		job := contract.RenderJob{Preview: true}
		job.Input.Path = input
		folder, err := os.MkdirTemp(dir, "preview-")
		if err != nil {
			t.Fatal(err)
		}
		job.Output.Path, job.Output.Format = filepath.Join(folder, fmt.Sprintf("%d.jpg", i)), "jpeg"
		result, err := c.Render(context.Background(), job, nil)
		if err != nil {
			t.Fatal(err)
		}
		var actual struct {
			SourceCacheHit bool
			Source         string
		}
		if json.Unmarshal(result, &actual) != nil || actual.SourceCacheHit != expectedHit {
			t.Fatalf("工作 %d 快取不符：%s", i, result)
		}
		paths = append(paths, actual.Source)
		output, _ := os.ReadFile(job.Output.Path)
		expected, _ := os.ReadFile(input)
		if string(output) != string(expected) {
			t.Fatal("使用了過期來源")
		}
		// 真實宿主在顯示後會移除整個輸出目錄；快照仍必須可供下次使用。
		if err := os.RemoveAll(folder); err != nil {
			t.Fatal(err)
		}
	}
	c.Close()
	for _, path := range paths {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("來源快照未回收", path, err)
		}
	}
	leftovers, _ := filepath.Glob(filepath.Join(dir, ".filmdevelop-*"))
	if len(leftovers) != 0 {
		t.Fatal("暫存資料夾未回收", leftovers)
	}
}

func TestPreviewSourceSurvivesCancellationAndConcurrentReplacement(t *testing.T) {
	c, dir := sourceHelper(t), t.TempDir()
	input := filepath.Join(dir, "source.bmp")
	if err := os.WriteFile(input, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	job := contract.RenderJob{Preview: true, PreviewMaxPixel: 123}
	job.Input.Path = input
	job.Output.Path, job.Output.Format = filepath.Join(dir, "cancelled.jpg"), "jpeg"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() {
		_, err := c.Render(ctx, job, func(float64) { started <- struct{}{} })
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("原生工作未啟動")
	}
	cancel()
	if err := os.WriteFile(input, []byte("modified"), 0600); err != nil {
		t.Fatal(err)
	}
	next := job
	next.PreviewMaxPixel = 2048
	next.Output.Path = filepath.Join(dir, "next.jpg")
	if _, err := c.Render(context.Background(), next, nil); err != nil {
		t.Fatal("替換來源造成舊工作讀取失敗", err)
	}
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := os.Stat(job.Output.Path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("取消的工作仍發布成品")
	}
	if data, _ := os.ReadFile(next.Output.Path); string(data) != "modified" {
		t.Fatal("新的工作使用了舊來源")
	}
}
