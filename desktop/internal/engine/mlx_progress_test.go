//go:build !windows

package engine

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestMLXLegacyProgress(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(map[bool]string{false: "完成", true: "失敗"}[failure], func(t *testing.T) {
			root := t.TempDir()
			worker := filepath.Join(root, "Resources", "MLX", "photostyle-mlx")
			if err := os.MkdirAll(filepath.Dir(worker), 0700); err != nil {
				t.Fatal(err)
			}
			response := `{"text":"測試配方"}`
			if failure {
				response = `{"error":"模型無法載入"}`
			}
			if err := os.WriteFile(worker, []byte("#!/bin/sh\ncat >/dev/null\nprintf '%s' '"+response+"'\n"), 0700); err != nil {
				t.Fatal(err)
			}
			client := New(filepath.Join(root, "MacOS", "filmdevelop-engine"))
			var events []float64
			_, err := client.Call(context.Background(), "infer", contract.InferenceRequest{Format: "mlx", MaxTokens: 3072, ContextLimit: 12288}, func(value float64) { events = append(events, value) })
			if (err != nil) != failure || len(events) == 0 || events[0] != 1.0/7 {
				t.Fatal("MLX 未回報開始生成", err, events)
			}
			if failure && len(events) != 1 || !failure && (len(events) != 2 || events[1] != 6.0/7) {
				t.Fatal("MLX 完成狀態與 Swift 不符", events)
			}
		})
	}
}
