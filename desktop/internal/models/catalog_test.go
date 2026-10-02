package models

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestModelCatalogPairsAndRejectsMissingShards(t *testing.T) {
	root := t.TempDir()
	write := func(name string) {
		data := make([]byte, 32)
		copy(data, "GGUF")
		binary.LittleEndian.PutUint32(data[4:], 3)
		if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("Qwen3-VL-Q4_K_M.gguf")
	write("Qwen3-VL.mmproj-F16.gguf")
	write("broken-00001-of-00002.gguf")
	write(".hidden.gguf")
	entries, err := Scan(context.Background(), root)
	if err != nil || len(entries) != 2 {
		t.Fatal(err, entries)
	}
	if !entries[0].Ready || entries[0].Projector == "" || entries[1].Ready {
		t.Fatal(entries)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = Scan(ctx, root); err == nil {
		t.Fatal("掃描未取消")
	}
	for _, path := range []string{"../model.gguf", "a/CON.gguf", "a\\model.gguf", "a/..", "/absolute", "a/model.", "a/model "} {
		if ValidPath(path) {
			t.Fatal(path)
		}
	}
}
func TestRepositorySearchAndImmutablePlan(t *testing.T) {
	read := func(ctx context.Context, url string, target any) error {
		var data string
		if strings.Contains(url, "?search=") || strings.Contains(url, "&search=") {
			data = `[{"id":"owner/vision","siblings":[{"rfilename":"model.gguf"}]},{"id":"owner/mlx","siblings":[{"rfilename":"config.json"},{"rfilename":"model.safetensors"}]},{"id":"owner/text","siblings":[{"rfilename":"README.md"}]}]`
		} else {
			data = `{"id":"owner/vision","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","siblings":[{"rfilename":"model.gguf","size":32},{"rfilename":"mmproj.gguf","size":32},{"rfilename":"README.md","size":20}]}`
		}
		return json.Unmarshal([]byte(data), target)
	}
	results, err := Search(context.Background(), read, "vision", "mlx")
	if err != nil || len(results) != 1 || results[0].ID != "owner/mlx" {
		t.Fatal(err, results)
	}
	repo, err := Inspect(context.Background(), read, "owner/vision")
	if err != nil {
		t.Fatal(err)
	}
	plan, err := repo.GGUFPlan("model.gguf", "mmproj.gguf")
	if err != nil || len(plan) != 3 {
		t.Fatal(err, plan)
	}
	for _, f := range plan {
		if !strings.Contains(f.URL, "/resolve/"+repo.Revision+"/") {
			t.Fatal("下載未鎖定版本")
		}
	}
}
func TestSafetensorsAndMLXValidation(t *testing.T) {
	root := t.TempDir()
	metadata := map[string]any{"config.json": map[string]any{"model_type": "qwen3_vl", "vision_config": map[string]any{"hidden_size": 1}}, "preprocessor_config.json": map[string]any{"processor_class": "Qwen3VLProcessor"}, "tokenizer_config.json": map[string]any{"tokenizer_class": "Qwen2Tokenizer"}, "tokenizer.json": map[string]any{"model": map[string]any{"type": "BPE", "vocab": map[string]any{"a": 0}}}}
	for name, value := range metadata {
		data, _ := json.Marshal(value)
		if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	header := []byte(`{"visual.weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}`)
	data := make([]byte, 8)
	binary.LittleEndian.PutUint64(data, uint64(len(header)))
	data = append(data, header...)
	data = append(data, 0, 0, 0, 0)
	path := filepath.Join(root, "model.safetensors")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateMLX(context.Background(), root); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data[:len(data)-1], 0600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateMLX(context.Background(), root); err == nil {
		t.Fatal("接受截斷權重")
	}
	if model := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_MODEL"); model != "" {
		if err := ValidateMLX(context.Background(), model); err != nil {
			t.Fatal(err)
		}
	}
}
