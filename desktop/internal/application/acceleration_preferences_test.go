package application

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAccelerationDefaultsAndRestartPersistence(t *testing.T) {
	a := testApp(t)
	if a.computeBackend != "system" || a.rawDecoder != "system" {
		t.Fatal("新設定未採用系統原生")
	}
	a.capabilities = object{"computeBackends": []any{"system", "vulkan"}, "rawDecoders": []any{"system", "software"}}
	for _, choice := range []struct{ compute, raw string }{{"vulkan", "software"}, {"system", "system"}} {
		if err := a.handle(object{"action": "setComputeBackend", "backend": choice.compute}); err != nil {
			t.Fatal(err)
		}
		if err := a.handle(object{"action": "setRAWDecoderBackend", "backend": choice.raw}); err != nil {
			t.Fatal(err)
		}
		if err := a.setPreference("setShowAllFilms", object{"enabled": true}); err != nil {
			t.Fatal(err)
		}
		b, err := New("unused-engine")
		if err != nil {
			t.Fatal(err)
		}
		job := b.job("", a.defaults["original"], true)
		if job.ComputeBackend != choice.compute || job.Input.RawDecoder != choice.raw ||
			a.preferences.ComputeBackend != choice.compute || a.preferences.RAWDecoder != choice.raw {
			t.Fatal("加速選項未保存至重啟後的原生工作", job.ComputeBackend, job.Input.RawDecoder)
		}
	}
}

func TestRAWPreferenceFailureRollsBack(t *testing.T) {
	a := testApp(t)
	a.capabilities = object{"rawDecoders": []any{"system", "software"}}
	if err := os.MkdirAll(filepath.Join(os.Getenv("FILMDEVELOP_DATA_DIR"), "state", "preferences.json"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := a.handle(object{"action": "setRAWDecoderBackend", "backend": "software"}); err == nil {
		t.Fatal("設定寫入失敗卻回報成功")
	}
	if a.rawDecoder != "system" || a.preferences.RAWDecoder != "system" {
		t.Fatal("保存失敗仍切換了解析後端")
	}
}

func TestAccelerationAdaptsToDetectedCapabilities(t *testing.T) {
	a := testApp(t)
	a.computeBackend, a.rawDecoder = "vulkan", "software"
	a.capabilities = object{"computeBackends": []any{"system"}, "rawDecoders": []any{}}
	if err := a.reconcileAcceleration(); err != nil {
		t.Fatal(err)
	}
	if a.computeBackend != "system" || a.rawDecoder != "system" {
		t.Fatal("未回到可用的系統路徑")
	}
	if err := a.setRAWDecoderBackend("software"); err == nil {
		t.Fatal("放行未偵測到的解析器")
	}
	if err := a.setComputeBackend("vulkan"); err == nil {
		t.Fatal("放行未偵測到的 GPU")
	}
	b, err := New("unused-engine")
	if err != nil || b.computeBackend != "system" || b.rawDecoder != "system" {
		t.Fatal("偵測後的設定未持久化", err)
	}
	a.capabilities["rawDecoders"] = []any{"system"}
	if err := a.setRAWDecoderBackend("system"); err != nil {
		t.Fatal(err)
	}
}
