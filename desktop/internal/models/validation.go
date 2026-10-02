package models

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var processors = map[string]string{"paligemma": "PaliGemmaProcessor", "qwen2_vl": "Qwen2VLProcessor", "qwen2_5_vl": "Qwen2_5_VLProcessor", "qwen3_vl": "Qwen3VLProcessor", "qwen3_5": "Qwen3VLProcessor", "qwen3_5_moe": "Qwen3VLProcessor", "idefics3": "Idefics3Processor", "gemma3": "Gemma3Processor", "gemma4": "Gemma4Processor", "gemma4_unified": "Gemma4UnifiedProcessor", "smolvlm": "SmolVLMProcessor", "fastvlm": "FastVLMProcessor", "llava_qwen2": "FastVLMProcessor", "pixtral": "PixtralProcessor", "mistral3": "Mistral3Processor", "lfm2_vl": "Lfm2VlProcessor", "lfm2-vl": "Lfm2VlProcessor", "glm_ocr": "Glm46VProcessor"}

func ValidPath(name string) bool {
	if name == "" || strings.ContainsAny(name, `\:*?"<>|`) {
		return false
	}
	for _, c := range strings.Split(name, "/") {
		if c == "" || c == "." || c == ".." || strings.HasPrefix(c, ".") || strings.HasSuffix(c, ".") || strings.HasSuffix(c, " ") {
			return false
		}
		for _, r := range c {
			if r < 32 || r == 127 {
				return false
			}
		}
		stem := strings.ToUpper(strings.Split(c, ".")[0])
		if stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || regexpDevice(stem) {
			return false
		}
	}
	return true
}
func regexpDevice(v string) bool {
	return len(v) == 4 && (strings.HasPrefix(v, "COM") || strings.HasPrefix(v, "LPT")) && v[3] >= '1' && v[3] <= '9'
}
func checkedPath(root, name string) (string, error) {
	if !ValidPath(name) {
		return "", errors.New("模型檔案路徑無效")
	}
	root, e := filepath.EvalSymlinks(root)
	if e != nil {
		return "", e
	}
	p, e := filepath.EvalSymlinks(filepath.Join(root, filepath.FromSlash(name)))
	if e != nil {
		return "", e
	}
	rel, e := filepath.Rel(root, p)
	if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("模型符號連結超出目錄")
	}
	info, e := os.Stat(p)
	if e != nil {
		return "", e
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("模型檔案不是一般檔案")
	}
	return p, nil
}
func JSONFile(root, name string, limit int64, target any) error {
	p, e := checkedPath(root, name)
	if e != nil {
		return e
	}
	f, e := os.Open(p)
	if e != nil {
		return e
	}
	defer f.Close()
	data, e := io.ReadAll(io.LimitReader(f, limit+1))
	if e != nil {
		return e
	}
	if int64(len(data)) > limit {
		return errors.New("模型中繼資料過大")
	}
	return json.Unmarshal(data, target)
}
func MLXCandidate(root string) bool {
	var config map[string]any
	if JSONFile(root, "config.json", 4<<20, &config) != nil {
		return false
	}
	typ, _ := config["model_type"].(string)
	vision, _ := config["vision_config"].(map[string]any)
	return processors[typ] != "" && len(vision) > 0
}
func ValidateMLX(ctx context.Context, root string) error {
	var config, processor, tokenizerConfig, tokenizer map[string]any
	if e := JSONFile(root, "config.json", 4<<20, &config); e != nil {
		return e
	}
	typ, _ := config["model_type"].(string)
	vision, _ := config["vision_config"].(map[string]any)
	if processors[typ] == "" || len(vision) == 0 {
		return errors.New("模型缺少支援的視覺架構或 vision_config")
	}
	name := "preprocessor_config.json"
	if _, e := os.Stat(filepath.Join(root, name)); errors.Is(e, os.ErrNotExist) {
		name = "processor_config.json"
	}
	if e := JSONFile(root, name, 4<<20, &processor); e != nil {
		return e
	}
	class, _ := processor["processor_class"].(string)
	if class == "" || (typ != "mistral3" && typ != "gemma4_unified" && class != processors[typ]) {
		return errors.New("影像處理器與模型架構不相容")
	}
	if e := JSONFile(root, "tokenizer_config.json", 4<<20, &tokenizerConfig); e != nil {
		return e
	}
	if len(tokenizerConfig) == 0 {
		return errors.New("分詞器設定是空的")
	}
	if e := JSONFile(root, "tokenizer.json", 128<<20, &tokenizer); e != nil {
		return e
	}
	model, _ := tokenizer["model"].(map[string]any)
	if model["type"] == nil {
		return errors.New("分詞器類型缺失")
	}
	vocabOK := false
	switch v := model["vocab"].(type) {
	case map[string]any:
		vocabOK = len(v) > 0
	case []any:
		vocabOK = len(v) > 0
	}
	if !vocabOK {
		return errors.New("分詞器詞彙表缺失")
	}
	var index struct {
		WeightMap map[string]string `json:"weight_map"`
	}
	indexed := false
	if _, e := os.Stat(filepath.Join(root, "model.safetensors.index.json")); e == nil {
		if e = JSONFile(root, "model.safetensors.index.json", 32<<20, &index); e != nil {
			return e
		}
		indexed = true
		if len(index.WeightMap) == 0 {
			return errors.New("權重索引是空的")
		}
	}
	weights := map[string]string{}
	count := 0
	e := filepath.WalkDir(root, func(p string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if e = ctx.Err(); e != nil {
			return e
		}
		if p != root && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		count++
		if count > 10000 {
			return errors.New("模型檔案過多")
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".safetensors") {
			rel, e := filepath.Rel(root, p)
			if e != nil {
				return e
			}
			rel = filepath.ToSlash(rel)
			resolved, e := checkedPath(root, rel)
			if e != nil {
				return e
			}
			weights[rel] = resolved
		}
		return nil
	})
	if e != nil {
		return e
	}
	if len(weights) == 0 || (!indexed && len(weights) != 1) {
		return errors.New("權重檔缺失或多個分片缺少索引")
	}
	if indexed {
		expected := map[string]bool{}
		for _, p := range index.WeightMap {
			if !ValidPath(p) || weights[p] == "" {
				return fmt.Errorf("權重分片不存在：%s", p)
			}
			expected[p] = true
		}
		if len(expected) != len(weights) {
			return errors.New("權重分片與索引不一致")
		}
	}
	names := map[string]bool{}
	hasVision := false
	for name, p := range weights {
		if e = ctx.Err(); e != nil {
			return e
		}
		keys, e := ValidateSafetensors(p)
		if e != nil {
			return e
		}
		for _, k := range keys {
			if names[k] || (indexed && index.WeightMap[k] != name) {
				return errors.New("權重重複或與索引不一致")
			}
			names[k] = true
			for _, part := range strings.Split(k, ".") {
				if part == "visual" || strings.HasPrefix(part, "vision") {
					hasVision = true
				}
			}
		}
	}
	if indexed && len(names) != len(index.WeightMap) {
		return errors.New("權重索引列出部分不存在的 tensor")
	}
	if !hasVision {
		return errors.New("模型沒有視覺編碼器權重")
	}
	return nil
}
func ValidateSafetensors(path string) ([]string, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return nil, e
	}
	var prefix [8]byte
	if _, e = io.ReadFull(f, prefix[:]); e != nil {
		return nil, e
	}
	length := binary.LittleEndian.Uint64(prefix[:])
	if length < 2 || length > 32<<20 || length+8 > uint64(info.Size()) {
		return nil, errors.New("safetensors 檔頭不完整")
	}
	data := make([]byte, length)
	if _, e = io.ReadFull(f, data); e != nil {
		return nil, e
	}
	var tensors map[string]json.RawMessage
	if e = json.Unmarshal(data, &tensors); e != nil {
		return nil, e
	}
	widths := map[string]uint64{"BOOL": 1, "I8": 1, "U8": 1, "I16": 2, "U16": 2, "I32": 4, "U32": 4, "I64": 8, "U64": 8, "F16": 2, "BF16": 2, "F32": 4, "F64": 8, "F8_E4M3": 1, "F8_E5M2": 1, "F8_E4M3FN": 1, "F8_E4M3FNUZ": 1, "F8_E5M2FNUZ": 1}
	ranges := [][2]uint64{}
	names := []string{}
	payload := uint64(info.Size()) - 8 - length
	for name, raw := range tensors {
		if name == "__metadata__" {
			continue
		}
		var t struct {
			DType   string   `json:"dtype"`
			Shape   []uint64 `json:"shape"`
			Offsets []uint64 `json:"data_offsets"`
		}
		if e = json.Unmarshal(raw, &t); e != nil {
			return nil, e
		}
		width := widths[t.DType]
		if name == "" || width == 0 || len(t.Offsets) != 2 || t.Offsets[0] > t.Offsets[1] || t.Offsets[1] > payload {
			return nil, errors.New("tensor 型別或範圍不符")
		}
		for _, d := range t.Shape {
			if d > 0 && width > math.MaxUint64/d {
				return nil, errors.New("tensor 維度溢位")
			}
			width *= d
		}
		if width != t.Offsets[1]-t.Offsets[0] {
			return nil, errors.New("tensor 大小與維度不符")
		}
		names = append(names, name)
		ranges = append(ranges, [2]uint64{t.Offsets[0], t.Offsets[1]})
	}
	sort.Slice(ranges, func(i, j int) bool {
		if ranges[i][0] != ranges[j][0] {
			return ranges[i][0] < ranges[j][0]
		}
		return ranges[i][1] < ranges[j][1]
	})
	cursor := uint64(0)
	for _, r := range ranges {
		if r[0] != cursor {
			return nil, errors.New("tensor 資料重疊或缺漏")
		}
		cursor = r[1]
	}
	if len(names) == 0 || cursor != payload {
		return nil, errors.New("safetensors 資料長度不符")
	}
	return names, nil
}
