package application

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

// 明確指定引擎、照片及報告位置才量測；不修改原照片或使用者的編輯紀錄。
func TestPreviewPerformanceSmoke(t *testing.T) {
	binary, input, destination := os.Getenv("FILMDEVELOP_PERF_ENGINE"), os.Getenv("FILMDEVELOP_PERF_IMAGE"), os.Getenv("FILMDEVELOP_PERF_OUTPUT")
	if binary == "" || input == "" || destination == "" {
		t.Skip("需指定預覽效能量測環境")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	var results []object
	for _, full := range []bool{false, true} {
		a := testApp(t)
		a.ctx = ctx
		a.preferences.OriginalResolution = full
		a.services, _ = host.New(engine.New(binary))
		a.thumbnailServices, _ = host.New(engine.New(binary))
		t.Cleanup(func() { a.services.Close(); a.thumbnailServices.Close() })
		measure := func(name string, start func() error) {
			t.Helper()
			began := time.Now()
			if err := start(); err != nil {
				t.Fatal(err)
			}
			a.workers.Wait()
			elapsed := time.Since(began)
			if a.previewError != nil || a.outputPreview == "" {
				t.Fatal("預覽未完成", a.previewError)
			}
			row := object{"case": name, "fullResolution": full, "milliseconds": float64(elapsed.Microseconds()) / 1000,
				"imagePayloadBytes": len(a.sourcePreview) + len(a.cropPreview) + len(a.outputPreview), "native": clone(a.renderInfo)}
			results = append(results, row)
			t.Logf("%s 原尺寸=%v %.1f ms，影像資料 %d bytes", name, full, row["milliseconds"], row["imagePayloadBytes"])
		}
		measure("開啟 RAW", func() error { return a.OpenImage(input) })
		measure("切換 Ektar 100", func() error {
			if err := a.selectStyle("filmEktar100"); err != nil {
				return err
			}
			a.preview()
			return nil
		})
		for _, exposure := range []float64{6, 12, 6} {
			measure("調整曝光", func() error {
				if err := a.update(object{"key": "exposure", "value": exposure}); err != nil {
					return err
				}
				a.preview()
				return nil
			})
		}
		a.services.Close()
		a.thumbnailServices.Close()
	}
	data, _ := json.MarshalIndent(object{"source": filepath.Base(input), "results": results}, "", "  ")
	if err := os.WriteFile(destination, append(data, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
}
