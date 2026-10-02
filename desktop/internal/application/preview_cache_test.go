package application

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

func TestPreviewCacheAcrossFilmsAndPhotos(t *testing.T) {
	a := testApp(t)
	var bitmap bytes.Buffer
	_ = png.Encode(&bitmap, image.NewRGBA(image.Rect(0, 0, 4, 3)))
	first, second := filepath.Join(t.TempDir(), "一.png"), filepath.Join(t.TempDir(), "二.png")
	for _, path := range []string{first, second} {
		if err := os.WriteFile(path, bitmap.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
	}
	var calls atomic.Int32
	backend := previewBackend{
		thumbnail: func(context.Context, string) ([]byte, error) { return bitmap.Bytes(), nil },
		render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
			calls.Add(1)
			result, _ := json.Marshal(object{"sourceWidth": 4, "sourceHeight": 3, "testStyle": job.Recipe.Style})
			return result, os.WriteFile(job.Output.Path, bitmap.Bytes(), 0600)
		},
	}
	a.services, _ = host.New(backend)
	a.thumbnailServices, _ = host.New(backend)
	check := func(expected int32) {
		t.Helper()
		a.workers.Wait()
		if a.previewError != nil || a.outputPreview == "" || calls.Load() != expected || a.renderInfo["testStyle"] != a.selected {
			t.Fatal("快取命中或顯影配方不符", expected, calls.Load(), a.previewError, a.renderInfo)
		}
	}
	open := func(path string, expected int32) {
		t.Helper()
		if err := a.OpenImage(path); err != nil {
			t.Fatal(err)
		}
		check(expected)
	}
	film := func(id string, expected int32) {
		t.Helper()
		if err := a.selectStyle(id); err != nil {
			t.Fatal(err)
		}
		a.preview()
		check(expected)
	}
	open(first, 1)
	film("filmEktar100", 2)
	film("filmPortra400", 3)
	film("filmEktar100", 3)
	open(second, 4)
	open(first, 4)
	if a.selected != "filmEktar100" {
		t.Fatal("切回照片未恢復配方")
	}
	a.computeBackend = "vulkan"
	a.preview()
	check(5)
	a.preferences.LensCorrection = !a.preferences.LensCorrection
	a.preview()
	check(6)
}

func TestPreviewCacheIdentifiesContentAndCompleteSettings(t *testing.T) {
	a := testApp(t)
	a.source = filepath.Join(t.TempDir(), "照片.raw")
	if err := os.WriteFile(a.source, []byte("相同大小的來源甲"), 0600); err != nil {
		t.Fatal(err)
	}
	job := a.job("成品一.jpg", a.defaults["original"], true)
	key, err := previewResultKey(a.ctx, job)
	if err != nil {
		t.Fatal(err)
	}
	other := clone(job)
	other.Output.Path = "成品二.jpg"
	if actual, _ := previewResultKey(a.ctx, other); actual != key {
		t.Fatal("暫存路徑使同一結果失效")
	}
	for _, change := range []func(*contract.RenderJob){
		func(j *contract.RenderJob) { j.Input.RawDecoder = "software" },
		func(j *contract.RenderJob) { j.Input.LensCorrection = !j.Input.LensCorrection },
		func(j *contract.RenderJob) { j.ComputeBackend = "vulkan" },
		func(j *contract.RenderJob) { j.Policy.FullResolution = !j.Policy.FullResolution },
		func(j *contract.RenderJob) { j.Policy.Hdr = !j.Policy.Hdr },
		func(j *contract.RenderJob) { j.Recipe.DetectSubject = !j.Recipe.DetectSubject },
		func(j *contract.RenderJob) { j.Recipe = a.defaults["filmEktar100"] },
		func(j *contract.RenderJob) { j.Recipe.RepairPatches = json.RawMessage(`[{"id":"新修復"}]`) },
		func(j *contract.RenderJob) { j.PreviewMaxPixel = 1024 },
		func(j *contract.RenderJob) { j.Output.Quality = .5 },
	} {
		changed := clone(job)
		change(&changed)
		if actual, _ := previewResultKey(a.ctx, changed); actual == key {
			t.Fatal("運算設定改變後仍重用舊成品")
		}
	}
	info, _ := os.Stat(a.source)
	if err = os.WriteFile(a.source, []byte("相同大小的來源乙"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.Chtimes(a.source, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	if actual, _ := previewResultKey(a.ctx, job); actual == key {
		t.Fatal("同路徑、大小與時間戳的內容變更未使快取失效")
	}
}

func TestPreviewCacheBoundsAndRecency(t *testing.T) {
	var cache previewResultCache
	for _, key := range []string{"一", "二", "三", "四", "五", "六"} {
		cache.put(cachedPreview{key: key, output: key})
	}
	_, _ = cache.get("一")
	cache.put(cachedPreview{key: "七", output: "七"})
	if _, found := cache.get("二"); found || len(cache.entries) != previewCacheEntries {
		t.Fatal("未淘汰最久未使用的成品")
	}
	if _, found := cache.get("一"); !found {
		t.Fatal("淘汰了剛使用的成品")
	}
	large := strings.Repeat("x", previewCacheBytes/2)
	cache.put(cachedPreview{key: "大一", output: large})
	cache.put(cachedPreview{key: "大二", output: large})
	if cache.bytes != previewCacheBytes || len(cache.entries) != 2 {
		t.Fatal("未限制記憶體用量", cache.bytes)
	}
	cache.put(cachedPreview{key: "過大", output: large + "x", result: []byte(large)})
	if _, found := cache.get("過大"); found || cache.bytes > previewCacheBytes {
		t.Fatal("過大成品不應進入快取")
	}
}

func TestPreviewImageDeltaAndFullResync(t *testing.T) {
	a := testApp(t)
	var state object
	a.emit = func(name string, payload any) {
		if name == "handleNativeState" {
			state = payload.(object)
		}
	}
	a.sourcePreview, a.cropPreview, a.outputPreview = "原圖", "裁切圖", "成品"
	a.state()
	if state["outputImage"] != "成品" || state["sourceImage"] != "原圖" {
		t.Fatal("首次狀態缺少影像")
	}
	a.rendering = true
	a.state()
	if _, repeated := state["outputImage"]; repeated || state["isRenderingPreview"] != true {
		t.Fatal("普通進度重送未變的成品")
	}
	a.outputPreview = "新成品"
	a.state()
	if state["outputImage"] != "新成品" {
		t.Fatal("變更的影像未送出")
	}
	if _, repeated := state["sourceImage"]; repeated {
		t.Fatal("未變的原圖不應重送")
	}
	if err := a.handle(object{"action": "getState"}); err != nil {
		t.Fatal(err)
	}
	if state["outputImage"] != "新成品" || state["sourceImage"] != "原圖" {
		t.Fatal("畫面重新連線未完整同步")
	}
	a.sourcePreview, a.cropPreview, a.outputPreview = "", "", ""
	a.state()
	for _, key := range []string{"sourceImage", "cropSourceImage", "repairSourceImage", "outputImage"} {
		if state[key] != "" {
			t.Fatal("清除照片必須明確移除舊圖", key)
		}
	}
}
