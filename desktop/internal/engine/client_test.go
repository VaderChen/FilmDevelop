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

// 使用真實子程序檢驗取消與輸出發布，不以模擬 Call 取代生命週期。
func TestWorkerProcess(t *testing.T) {
	mode := os.Getenv("FILMDEVELOP_TEST_WORKER")
	if mode == "" {
		return
	}
	var request contract.Request
	if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil {
		os.Exit(2)
	}
	if mode == "wait" {
		time.Sleep(time.Minute)
		os.Exit(2)
	}
	if mode == "missing" {
		os.Exit(0)
	}
	response := contract.Response{Version: 1, ID: request.ID, Kind: "result", Payload: json.RawMessage(`{"ok":true}`)}
	if mode == "wrong-id" {
		response.ID = "stale"
	}
	if mode == "native-error" {
		response.Kind = "error"
		response.Error = &contract.EngineError{Code: "unsupportedParameter", Message: "未支援的欄位"}
	}
	if request.Method == "render" {
		var job contract.RenderJob
		if err := json.Unmarshal(request.Payload, &job); err != nil {
			os.Exit(2)
		}
		if err := os.WriteFile(job.Output.Path, []byte("已完成的測試成品"), 0600); err != nil {
			os.Exit(2)
		}
		if mode == "partial" {
			os.Exit(2)
		}
	}
	_ = json.NewEncoder(os.Stdout).Encode(response)
	if mode == "duplicate" {
		_ = json.NewEncoder(os.Stdout).Encode(response)
	}
	os.Exit(0)
}

func helper(mode string) *Client {
	c := New(os.Args[0])
	c.command = func(ctx context.Context) *exec.Cmd {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestWorkerProcess$")
		cmd.Env = append(os.Environ(), "FILMDEVELOP_TEST_WORKER="+mode)
		return cmd
	}
	return c
}

func TestProtocolFailures(t *testing.T) {
	for _, mode := range []string{"wrong-id", "missing", "duplicate", "native-error"} {
		t.Run(mode, func(t *testing.T) {
			_, err := helper(mode).Call(context.Background(), "capabilities", nil, nil)
			if err == nil {
				t.Fatal("錯誤回覆不可視為成功")
			}
			if mode == "native-error" {
				var native *NativeError
				if !errors.As(err, &native) || native.Code != "unsupportedParameter" {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestCancelReapsProcessAndAllowsNextJob(t *testing.T) {
	c := helper("wait")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := c.Call(ctx, "render", nil, nil)
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) > 3*time.Second {
		t.Fatalf("取消失敗：%v", err)
	}
	c.command = helper("ok").command
	if _, err := c.Call(context.Background(), "capabilities", nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestOutputTransaction(t *testing.T) {
	for _, mode := range []string{"ok", "partial", "wrong-id", "missing"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			source, target := filepath.Join(root, "原圖.png"), filepath.Join(root, "成品.png")
			if err := os.WriteFile(source, []byte("原始照片"), 0600); err != nil {
				t.Fatal(err)
			}
			job := contract.RenderJob{Input: contract.ImageInput{Path: source}, Output: contract.ImageOutput{Path: target, Format: "png"}}
			_, err := helper(mode).Render(context.Background(), job, nil)
			_, exists := os.Stat(target)
			if mode == "ok" {
				if err != nil || exists != nil {
					t.Fatalf("成品未發布：%v / %v", err, exists)
				}
				if _, err := helper(mode).Render(context.Background(), job, nil); err == nil {
					t.Fatal("覆寫已存在的成品")
				}
			} else if err == nil || !os.IsNotExist(exists) {
				t.Fatalf("失敗工作發布了成品：%v", err)
			}
			data, _ := os.ReadFile(source)
			if string(data) != "原始照片" {
				t.Fatal("原圖遭到修改")
			}
			pending, _ := filepath.Glob(filepath.Join(root, ".filmdevelop-work-*"))
			if len(pending) != 0 {
				t.Fatal(fmt.Sprint("工作未清理：", pending))
			}
		})
	}
}

func TestPublicationDoesNotReplaceRacingOutput(t *testing.T) {
	root := t.TempDir()
	source, target := filepath.Join(root, "暫存.png"), filepath.Join(root, "成品.png")
	if err := os.WriteFile(source, []byte("新成品"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("同時產生的舊成品"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := publish(source, target); err == nil {
		t.Fatal("競爭寫入覆蓋了已有成品")
	}
	content, err := os.ReadFile(target)
	if err != nil || string(content) != "同時產生的舊成品" {
		t.Fatal("已有成品未被保留", err)
	}
}
