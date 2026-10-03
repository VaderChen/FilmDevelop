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
	"github.com/VaderChen/FilmDevelop/internal/models"
)

type parityAIBackend struct {
	previewBackend
	infer func(context.Context, func(float64)) (json.RawMessage, error)
}

func (b parityAIBackend) Call(ctx context.Context, method string, input any, progress func(float64)) (json.RawMessage, error) {
	switch method {
	case "analysis":
		return json.RawMessage(`{"imageData":"測試影像","analysis":"測試分析"}`), nil
	case "infer":
		return b.infer(ctx, progress)
	default:
		return b.previewBackend.Call(ctx, method, input, progress)
	}
}

func TestSwiftParityAILifecycle(t *testing.T) {
	for _, cancelRun := range []bool{false, true} {
		t.Run(map[bool]string{false: "成功後等待預覽", true: "取消後拒絕較晚結果"}[cancelRun], func(t *testing.T) {
			a, path := restoredParityApp(t)
			a.selected = "filmGold200"
			a.modelEntries = []models.Entry{{ID: "測試模型", Format: "gguf", Ready: true}}
			a.modelSettings = modelSettings{Enabled: true, Selected: "測試模型"}
			plan, err := os.ReadFile("../recipes/plan.json")
			if err != nil {
				t.Fatal(err)
			}
			var fields object
			if err = json.Unmarshal(plan, &fields); err != nil {
				t.Fatal(err)
			}
			fields["strength"] = float64(37)
			plan, _ = json.Marshal(fields)
			answer, _ := json.Marshal(object{"text": string(plan)})
			started, release := make(chan struct{}), make(chan struct{})
			var mu sync.Mutex
			var states []object
			renders := 0
			a.emit = func(name string, payload any) {
				if name == "handleNativeState" {
					mu.Lock()
					states = append(states, payload.(object))
					mu.Unlock()
				}
			}
			backend := parityAIBackend{infer: func(ctx context.Context, progress func(float64)) (json.RawMessage, error) {
				if progress == nil {
					return nil, errors.New("AI 進度回呼未接上")
				}
				progress(2.0 / 7)
				close(started)
				if cancelRun {
					<-ctx.Done()
					<-release
				}
				return answer, nil
			}, previewBackend: previewBackend{render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
				mu.Lock()
				renders++
				mu.Unlock()
				if !job.Recipe.DetectSubject {
					return nil, errors.New("AI 未偵測主體")
				}
				image, err := os.ReadFile(path)
				if err != nil {
					return nil, err
				}
				return json.RawMessage(`{"sourceWidth":4,"sourceHeight":3,"cropWidth":4,"cropHeight":3}`), os.WriteFile(job.Output.Path, image, 0600)
			}}}
			a.services, err = host.New(backend)
			if err != nil {
				t.Fatal(err)
			}
			if err = a.applyAIWith("", ""); err != nil {
				t.Fatal(err)
			}
			select {
			case <-started:
			case <-time.After(5 * time.Second):
				t.Fatal("AI 未啟動")
			}
			if cancelRun {
				a.cancelAI()
				close(release)
			}
			a.workers.Wait()
			mu.Lock()
			defer mu.Unlock()
			progressSeen, expanded, cancelling := false, false, false
			for _, state := range states {
				progressSeen = progressSeen || state["computationCompletedItems"] == float64(2)
				expanded = expanded || state["expandAdjustments"] == true
				cancelling = cancelling || state["isCancellingComputation"] == true
			}
			if !progressSeen || a.computing || a.cancellingComputation {
				t.Fatal("AI 進度或收尾不符")
			}
			if cancelRun {
				if renders != 0 || expanded || !cancelling || recipeFields(a.recipes[a.selected])["intensity"] == float64(37) {
					t.Fatal("取消仍套用結果", renders, expanded, cancelling)
				}
			} else {
				if renders != 1 || !expanded || a.outputPreview == "" || recipeFields(a.recipes[a.selected])["intensity"] != float64(37) {
					t.Fatal("AI 完成未產生預覽或展開調整", renders, expanded, a.previewError)
				}
			}
		})
	}
}

func TestSwiftParityExportFailurePreservesDestination(t *testing.T) {
	for _, failure := range []string{"render", "cancel", "changed", "source", "alias"} {
		t.Run(failure, func(t *testing.T) {
			a, source := restoredParityApp(t)
			target := filepath.Join(t.TempDir(), "成品.png")
			if err := os.WriteFile(target, []byte("既有成品"), 0600); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(source)
			ctx, cancel := context.WithCancel(a.ctx)
			defer cancel()
			backend := previewBackend{render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
				if failure == "render" {
					return nil, errors.New("編碼失敗")
				}
				if failure == "cancel" {
					cancel()
				}
				if failure == "changed" {
					if err := os.WriteFile(target, []byte("其他操作的新版本"), 0600); err != nil {
						return nil, err
					}
				}
				return json.RawMessage(`{}`), os.WriteFile(job.Output.Path, []byte("新成品"), 0600)
			}}
			var err error
			a.services, err = host.New(backend)
			if err != nil {
				t.Fatal(err)
			}
			if failure == "source" {
				target = source
			}
			if failure == "alias" {
				target = filepath.Join(t.TempDir(), "來源連結.jpg")
				if err = os.Link(source, target); err != nil {
					t.Fatal(err)
				}
			}
			var phases []string
			a.emit = func(name string, value any) {
				if name == "handleExportDevelopment" {
					phases = append(phases, value.(object)["phase"].(string))
				}
			}
			_, err = a.renderExport(ctx, a.job(target, a.recipes[a.selected], false), true)
			if err == nil {
				t.Fatal("失敗工作不應成功")
			}
			if len(phases) < 2 || phases[len(phases)-1] != "cancel" {
				t.Fatal("失敗後未關閉顯影對話框", phases)
			}
			after, _ := os.ReadFile(source)
			if string(before) != string(after) {
				t.Fatal("破壞來源照片")
			}
			if failure == "render" || failure == "cancel" {
				data, _ := os.ReadFile(target)
				if string(data) != "既有成品" {
					t.Fatal("破壞既有成品")
				}
			}
			if failure == "changed" {
				data, _ := os.ReadFile(target)
				if string(data) != "其他操作的新版本" {
					t.Fatal("覆寫其他操作的新版本")
				}
			}
			pending, _ := filepath.Glob(filepath.Join(filepath.Dir(target), ".filmdevelop-export-*"))
			if len(pending) != 0 {
				t.Fatal("遺留暫存", pending)
			}
		})
	}
}

func TestSwiftParityDropUsesNativeOpenHandshake(t *testing.T) {
	a, path := restoredParityApp(t)
	if err := a.openDroppedPhotos([]string{path, path}); err == nil {
		t.Fatal("接受多個拖入檔案")
	}
	if err := a.openDroppedPhotos([]string{path}); err != nil {
		t.Fatal(err)
	}
	if a.pendingNativeFile != path {
		t.Fatal("未走可提交前端編輯的原生開檔流程")
	}
}
