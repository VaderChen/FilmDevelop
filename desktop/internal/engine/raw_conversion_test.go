package engine

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

func TestRAWConversionCacheValidatesContentAndConverter(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	converter := filepath.Join(dir, "converter")
	if err := os.WriteFile(converter, []byte("converter-v1"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FILMDEVELOP_DNG_CONVERTER", converter)
	cache := &rawConversionCache{}
	_, identity, err := cache.converter(ctx)
	if err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(dir, "source.nef")
	if err := os.WriteFile(source, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(source)
	sourceHash, _ := rawDigest(ctx, source)
	converted := filepath.Join(dir, "cached")
	if err := os.Mkdir(converted, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(converted, "image.dng")
	if err := os.WriteFile(path, []byte("converted"), 0600); err != nil {
		t.Fatal(err)
	}
	hash, _ := rawDigest(ctx, path)
	entry := rawConversion{key: sourceHash, extension: ".nef", backend: "software", converterID: identity, path: path, directory: converted, digest: hash, size: 9}
	cache.remember(entry)
	input := contract.ImageInput{Path: source, RawDecoder: "software"}
	if _, ok, err := cache.lookup(ctx, input); err != nil || !ok {
		t.Fatal("未重用相同來源", err)
	}
	// 相同大小與修改時間不能掩蓋原始照片內容變更。
	if err := os.WriteFile(source, []byte("modified"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(source, before.ModTime(), before.ModTime()); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := cache.lookup(ctx, input); err != nil || ok {
		t.Fatal("誤用舊來源快取", err)
	}
	if err := os.WriteFile(source, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(converter, []byte("new-converter-version"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := cache.lookup(ctx, input); err != nil || ok {
		t.Fatal("更換轉檔器未使快取失效", err)
	}
	_, identity, _ = cache.converter(ctx)
	cache.entries[0].converterID = identity
	if err := os.WriteFile(path, []byte("corrupted"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := cache.lookup(ctx, input); err != nil || ok {
		t.Fatal("損壞 DNG 被重用", err)
	}
	if _, err := os.Stat(converted); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("損壞快取未清理")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := rawDigest(cancelled, source); !errors.Is(err, context.Canceled) {
		t.Fatal("來源讀取未取消", err)
	}
}

// 使用真實 Adobe 轉檔器及原生引擎，覆蓋感光解碼、暖快取、完整解析與原檔保存。
// 明確提供清單才執行；Windows 可用 go test -c 產生相同測試執行檔。
func TestRAWConversionNativeSmoke(t *testing.T) {
	manifest, executable := os.Getenv("FILMDEVELOP_RAW_SMOKE_MANIFEST"), os.Getenv("FILMDEVELOP_NATIVE_SMOKE_ENGINE")
	if manifest == "" || executable == "" {
		t.Skip("需提供 RAW 清單與原生引擎")
	}
	data, err := os.ReadFile(manifest)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Cases []struct {
			ID, Path   string
			Conversion bool
		}
		Recipe  contract.Recipe
		Backend string
	}
	if err = json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	if config.Backend == "" {
		config.Backend = "software"
	}
	output := os.Getenv("FILMDEVELOP_RAW_SMOKE_OUTPUT")
	if output == "" {
		output = t.TempDir()
	}
	if err = os.MkdirAll(output, 0700); err != nil {
		t.Fatal(err)
	}
	c := New(executable)
	defer func() {
		root := ""
		if c.rawConversions != nil {
			root = c.rawConversions.root
		}
		_ = c.Close()
		if root != "" {
			if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
				t.Error("結束後未回收 RAW 快取")
			}
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	var rows []map[string]any
	for _, item := range config.Cases {
		t.Run(item.ID, func(t *testing.T) {
			original, err := rawDigest(ctx, item.Path)
			if err != nil {
				t.Fatal(err)
			}
			job := contract.RenderJob{Input: contract.ImageInput{Path: item.Path, RawDecoder: config.Backend}, Recipe: config.Recipe,
				Output:         contract.ImageOutput{Format: "png", BitDepth: 16, ColorSpace: "sRGB", Quality: .95, MaxPixel: 384, TiffCompression: 1},
				ComputeBackend: "system", Preview: true, PreviewMaxPixel: 384,
				Policy: &contract.RenderPolicy{HighlightProtection: true, Hdr: true}}
			var convertedPath string
			for pass := 0; pass < 3; pass++ {
				label := []string{"cold", "warm", "export"}[pass]
				job.Output.Path = filepath.Join(output, item.ID+"-"+label+".png")
				if pass == 2 {
					job.Preview = false
					yes := true
					job.Output.WriteExif = &yes
				}
				start := time.Now()
				result, err := c.Render(ctx, job, nil)
				if err != nil {
					t.Fatal(label, err)
				}
				var fields map[string]any
				if err = json.Unmarshal(result, &fields); err != nil {
					t.Fatal(err)
				}
				if fields["rawDecoder"] != "software" || fields["embeddedRAWPreview"] != false {
					t.Fatal("未使用完整感光資料", fields["rawDecoder"])
				}
				if (fields["rawConversion"] == "adobe-dng") != item.Conversion {
					t.Fatal("解碼路由與預期不符")
				}
				if item.Conversion && fields["systemRAWFallback"] != (config.Backend == "system") {
					t.Fatal("未回報系統解析的實際回退路徑")
				}
				if item.Conversion {
					entry, ok, err := c.rawConversions.lookup(ctx, job.Input)
					if err != nil || !ok {
						t.Fatal("缺少有效轉檔快取", err)
					}
					if pass > 0 && entry.path != convertedPath {
						t.Fatal("重複轉換同一原檔")
					}
					convertedPath = entry.path
				}
				if pass == 1 {
					timing, _ := fields["timing"].(map[string]any)
					hit := fields["sourceCacheHit"] == true || timing["sourceCacheHit"] == true
					if !hit {
						t.Fatal("連續預覽未重用原生解碼快取")
					}
				}
				delete(fields, "sourceImage")
				delete(fields, "cropImage")
				rows = append(rows, map[string]any{"id": item.ID, "pass": label, "milliseconds": time.Since(start).Milliseconds(), "sourceSHA256": original, "result": fields})
			}
			after, err := rawDigest(ctx, item.Path)
			if err != nil || after != original {
				t.Fatal("原始照片被更動", err)
			}
		})
	}
	data, _ = json.MarshalIndent(map[string]any{"passed": !t.Failed(), "cases": rows}, "", "  ")
	if err := os.WriteFile(filepath.Join(output, "report.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

// 使用沒有可用內嵌縮圖的 RAW，驗證列表實際使用的嚴格縮圖契約及重試路徑。
func TestRAWSupplementalThumbnailNativeSmoke(t *testing.T) {
	source, executable := os.Getenv("FILMDEVELOP_RAW_THUMBNAIL_SMOKE_INPUT"), os.Getenv("FILMDEVELOP_NATIVE_SMOKE_ENGINE")
	if source == "" || executable == "" {
		t.Skip("需提供補充解碼縮圖來源與原生引擎")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	before, err := rawDigest(ctx, source)
	if err != nil {
		t.Fatal(err)
	}
	c := New(executable)
	defer c.Close()
	service, err := host.New(c)
	if err != nil {
		t.Fatal(err)
	}
	var cachedPath string
	for pass := 0; pass < 2; pass++ {
		if _, err = service.Thumbnail(ctx, source); err != nil {
			t.Fatal("列表縮圖無法通過宿主驗證", err)
		}
		if c.rawConversions == nil || len(c.rawConversions.entries) != 1 {
			t.Fatal("縮圖未使用補充解碼")
		}
		entry := c.rawConversions.entries[0]
		if pass > 0 && entry.path != cachedPath {
			t.Fatal("重複轉換列表縮圖")
		}
		cachedPath = entry.path
	}
	if after, err := rawDigest(ctx, source); err != nil || after != before {
		t.Fatal("縮圖更動原始 RAW", err)
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(cachedPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("縮圖轉換快取未清理")
	}
}
