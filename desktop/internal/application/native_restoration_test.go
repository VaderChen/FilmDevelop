package application

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

// 以明確提供的本機模型執行 Smoke，不下載模型、不改動使用者資料。
func TestNativeRestoration(t *testing.T) {
	binary := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_ENGINE")
	if binary == "" {
		t.Skip("需指定本機原生引擎")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	service, err := host.New(engine.New(binary))
	if err != nil {
		t.Fatal(err)
	}
	input := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_IMAGE")
	data, err := service.Catalog()
	if err != nil {
		t.Fatal(err)
	}
	var catalog object
	_ = json.Unmarshal(data, &catalog)
	var recipe contract.Recipe
	for _, raw := range catalog["styles"].([]any) {
		s := raw.(object)
		if s["id"] == "filmGold200" {
			recipe = contract.Recipe{Version: 1, Style: s["id"].(string), RepairPatches: json.RawMessage(`[]`)}
			recipe.Adjustment, _ = json.Marshal(s["adjustment"])
			break
		}
	}
	if recipe.Style == "" {
		t.Fatal("缺少參考底片")
	}
	image := contract.ImageInput{Path: input, RawDecoder: "system", LensCorrection: true}
	data, err = service.Native(ctx, "analysis", contract.AnalysisRequest{Input: image, Recipe: recipe}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var analysis struct{ ImageData, Analysis string }
	if err = json.Unmarshal(data, &analysis); err != nil || analysis.ImageData == "" || analysis.Analysis == "" {
		t.Fatalf("分析不完整：%v", err)
	}
	t.Log("照片分析完成")
	if model := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_MODEL"); model != "" {
		prompt := "Inspect this photograph. Use the complete schema 6 from the system instruction. Set strength 37, post_processing.grain 0, all tone-zone grain 0, keep every other effect neutral. No crop, date or frame. Selected style Kodak Gold 200; color_mode color. Return only one complete JSON object."
		format, projector := "mlx", ""
		if strings.EqualFold(filepath.Ext(model), ".gguf") {
			format, projector = "gguf", os.Getenv("FILMDEVELOP_NATIVE_SMOKE_PROJECTOR")
			if projector == "" {
				t.Fatal("GGUF 視覺推論需指定投影模型")
			}
			prompt = "<image>\n" + prompt
		}
		data, err = service.Native(ctx, "infer", contract.InferenceRequest{Format: format, ModelPath: model, ProjectorPath: projector, ImageData: analysis.ImageData, SystemPrompt: defaultPrompts.System, UserPrompt: prompt, Grammar: defaultPrompts.Grammar, MaxTokens: 3072, ContextLimit: 12288}, nil)
		if err != nil {
			t.Fatal(err)
		}
		var result struct{ Text string }
		_ = json.Unmarshal(data, &result)
		_ = os.WriteFile(filepath.Join(t.TempDir(), "generated-plan.json"), []byte(result.Text), 0600)
		mapped, e := service.MapPlan(result.Text, recipe)
		if e != nil {
			t.Fatalf("配方無效：%v\n%s", e, result.Text)
		}
		if recipeFields(mapped)["intensity"] != float64(37) {
			t.Fatalf("模型未遵守明確數值：%s", result.Text)
		}
		recipe = mapped
		t.Log(format, "真實推論與 Go 配方驗證完成")
	}
	if directory := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_REPAIR"); directory != "" {
		_, err = service.Native(ctx, "prepareRepair", contract.FileRequest{Path: directory}, nil)
		if err != nil {
			t.Fatal(err)
		}
		patch, err := service.Native(ctx, "repair", contract.RepairRequest{Input: image, Recipe: recipe, ModelDirectory: directory, Strokes: json.RawMessage(`[{"radius":0.06,"points":[{"x":0.5,"y":0.5}]}]`)}, nil)
		if err != nil {
			t.Fatal(err)
		}
		var p object
		if json.Unmarshal(patch, &p) != nil || p["imageData"] == nil || p["maskData"] == nil {
			t.Fatal("修復回覆不完整")
		}
		recipe.RepairPatches, _ = json.Marshal([]json.RawMessage{patch})
		t.Log("原生模型真實修復完成")
	}
	path := filepath.Join(t.TempDir(), "result.png")
	_, err = service.Render(ctx, contract.RenderJob{Input: image, Recipe: recipe, Output: contract.ImageOutput{Path: path, Format: "png", BitDepth: 16, ColorSpace: "sRGB", Quality: .95, TiffCompression: 1, MaxPixel: 0}, ComputeBackend: "system", PreviewMaxPixel: 2048}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if info, e := os.Stat(path); e != nil || info.Size() == 0 {
		t.Fatal("匯出未完成")
	}
	t.Log("完整配方及修復紀錄的 16-bit 匯出完成")
}
