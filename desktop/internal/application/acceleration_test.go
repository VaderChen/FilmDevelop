package application

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

func recordComputeSwitch(a *App) func() (object, bool) {
	var mu sync.Mutex
	var latest object
	var observed bool
	a.emit = func(name string, payload any) {
		if name != "handleNativeState" {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		latest = payload.(object)
		observed = observed || latest["isSwitchingComputeBackend"] == true
	}
	return func() (object, bool) {
		mu.Lock()
		defer mu.Unlock()
		return latest, observed
	}
}

func TestComputeSwitchWaitsForItsPreview(t *testing.T) {
	for _, fails := range []bool{false, true} {
		t.Run(map[bool]string{false: "預覽完成", true: "引擎失敗"}[fails], func(t *testing.T) {
			a := testApp(t)
			a.capabilities = object{"computeBackends": []any{"system", "vulkan"}}
			a.source, a.outputPreview = "照片.jpg", "原有預覽"
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			a.ctx = ctx
			t.Cleanup(func() { cancel(); a.workers.Wait() })
			state := recordComputeSwitch(a)
			started, finish := make(chan contract.RenderJob, 1), make(chan struct{})
			a.services, _ = host.New(previewBackend{render: func(ctx context.Context, job contract.RenderJob) (json.RawMessage, error) {
				started <- job
				select {
				case <-finish:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				if fails {
					return nil, errors.New("測試引擎失敗")
				}
				return json.RawMessage(`{"sourceWidth":4,"sourceHeight":3}`), os.WriteFile(job.Output.Path, []byte("預覽結果"), 0600)
			}})
			if err := a.handle(object{"action": "setComputeBackend", "backend": "vulkan", "requestID": "切換一"}); err != nil {
				t.Fatal(err)
			}
			select {
			case job := <-started:
				if job.ComputeBackend != "vulkan" {
					t.Fatal("切換後仍使用舊後端")
				}
			case <-ctx.Done():
				t.Fatal("未開始切換預覽")
			}
			current, _ := state()
			if current["isSwitchingComputeBackend"] != true || current["computeBackendSwitchRequestID"] != "切換一" {
				t.Fatal("後端確認要求後，預覽未完成就解除等待", current["isSwitchingComputeBackend"])
			}
			a.mu.Lock()
			previousRevision := a.revision
			a.mu.Unlock()
			a.preview()
			select {
			case <-started:
			case <-ctx.Done():
				t.Fatal("未開始重排的預覽")
			}
			a.previewDone(previousRevision, "過期預覽", nil, nil)
			current, _ = state()
			if current["isSwitchingComputeBackend"] != true {
				t.Fatal("重排預覽或舊回覆提早解除等待")
			}
			if err := a.handle(object{"action": "updateAdjustment", "key": "exposure", "value": float64(12)}); err == nil {
				t.Fatal("切換時仍可插入其他編輯")
			}
			close(finish)
			a.workers.Wait()
			current, _ = state()
			if current["isSwitchingComputeBackend"] != false || current["isRenderingPreview"] != false {
				t.Fatal("預覽結束後未解除等待")
			}
			if fails && a.outputPreview != "原有預覽" {
				t.Fatal("失敗時遺失原有照片")
			}
			a.preview()
			current, _ = state()
			if current["isSwitchingComputeBackend"] != false {
				t.Fatal("一般預覽誤用切換對話框")
			}
			a.workers.Wait()
		})
	}
}

func TestComputeSwitchAlwaysAcknowledges(t *testing.T) {
	for _, test := range []struct {
		name, backend string
		setup         func(*App)
		fails, starts bool
	}{
		{name: "沒有照片", backend: "vulkan", starts: true},
		{name: "相同後端", backend: "system"},
		{name: "未知後端", backend: "invalid", fails: true},
		{name: "硬體不支援", backend: "vulkan", fails: true, setup: func(a *App) { a.capabilities = nil }},
		{name: "宿主尚未就緒", backend: "vulkan", fails: true, setup: func(a *App) { a.initError = errors.New("測試初始化失敗") }},
		{name: "正在匯出", backend: "vulkan", fails: true, setup: func(a *App) { a.saving = true }},
		{name: "設定保存失敗", backend: "vulkan", fails: true, starts: true, setup: func(a *App) {
			if err := os.MkdirAll(filepath.Join(os.Getenv("FILMDEVELOP_DATA_DIR"), "state", "preferences.json"), 0700); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			a := testApp(t)
			a.capabilities = object{"computeBackends": []any{"system", "vulkan"}}
			if test.setup != nil {
				test.setup(a)
			}
			state := recordComputeSwitch(a)
			err := a.handle(object{"action": "setComputeBackend", "backend": test.backend, "requestID": "本次要求"})
			if (err != nil) != test.fails {
				t.Fatal("切換結果不符", err)
			}
			current, observed := state()
			if current["isSwitchingComputeBackend"] != false || current["computeBackendSwitchRequestID"] != "本次要求" || observed != test.starts {
				t.Fatal("缺少要求確認或等待狀態未清除", observed, current["isSwitchingComputeBackend"])
			}
			if test.fails && a.computeBackend != "system" {
				t.Fatal("切換失敗未保留原有設定")
			}
		})
	}
}
