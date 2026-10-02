package engine

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestPreviewSessionWorker(t *testing.T) {
	if os.Getenv("FILMDEVELOP_TEST_SESSION") != "1" {
		return
	}
	decoder := json.NewDecoder(os.Stdin)
	for calls := 1; ; calls++ {
		var request contract.Request
		if decoder.Decode(&request) != nil {
			os.Exit(0)
		}
		var value map[string]bool
		_ = json.Unmarshal(request.Payload, &value)
		if value["wait"] {
			time.Sleep(300 * time.Millisecond)
		}
		id := request.ID
		if value["wrongID"] {
			id = "stale"
		}
		payload, _ := json.Marshal(map[string]int{"pid": os.Getpid(), "calls": calls})
		_ = json.NewEncoder(os.Stdout).Encode(contract.Response{Version: 1, ID: id, Kind: "result", Payload: payload})
	}
}

func previewHelper(t *testing.T) *Client {
	t.Helper()
	c := New(os.Args[0])
	c.command = func(ctx context.Context) *exec.Cmd {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPreviewSessionWorker$")
		cmd.Env = append(os.Environ(), "FILMDEVELOP_TEST_SESSION=1")
		return cmd
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestPreviewReusesProcessAndCloses(t *testing.T) {
	c := previewHelper(t)
	var first map[string]int
	for i := 1; i <= 3; i++ {
		result, err := c.Call(context.Background(), "preview", map[string]bool{}, nil)
		if err != nil {
			t.Fatal(err)
		}
		var current map[string]int
		if json.Unmarshal(result, &current) != nil || current["calls"] != i {
			t.Fatal("未重用程序", string(result))
		}
		if first == nil {
			first = current
		} else if first["pid"] != current["pid"] {
			t.Fatal("預覽程序被重建")
		}
	}
	p := c.preview
	c.Close()
	select {
	case <-p.done:
	default:
		t.Fatal("關閉後程序尚未收回")
	}
	if p.cmd.ProcessState == nil || c.preview != nil {
		t.Fatal("關閉後遺留原生程序")
	}
}

func TestPreviewCancellationDrainsAndProtocolFailureDiscardsSession(t *testing.T) {
	c := previewHelper(t)
	for _, value := range []map[string]bool{{"wait": true}, {"wrongID": true}} {
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		_, err := c.Call(ctx, "preview", value, nil)
		cancel()
		if err == nil {
			t.Fatal("失敗工作被視為成功")
		}
		if value["wait"] && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		if value["wrongID"] && c.preview != nil {
			t.Fatal("格式錯誤後仍保留程序")
		}
		result, err := c.Call(context.Background(), "preview", map[string]bool{}, nil)
		if err != nil {
			t.Fatal("無法重新啟動", err)
		}
		var next map[string]int
		_ = json.Unmarshal(result, &next)
		expected := 1
		if value["wait"] {
			expected = 2
		}
		if next["calls"] != expected {
			t.Fatal("過期工作污染新的程序", string(result))
		}
	}
}
