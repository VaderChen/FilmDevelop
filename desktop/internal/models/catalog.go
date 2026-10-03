// Package models 管理模型目錄、配對與中繼資料驗證；不載入權重或執行推論。
package models

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type Entry struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Format    string `json:"format"`
	Ready     bool   `json:"ready"`
	Message   string `json:"message"`
	Path      string `json:"path"`
	Projector string `json:"projector"`
	Managed   bool   `json:"managed"`
}

func IsProjector(path string) bool {
	name := strings.ToLower(filepath.Base(path))
	return strings.HasSuffix(name, ".gguf") && (strings.Contains(name, "mmproj") || strings.Contains(name, "vision-encoder") || strings.Contains(name, "projector"))
}

var quantization = regexp.MustCompile(`([._-](q[0-9]+(_[a-z0-9]+)*|f16|bf16|fp16|f32))+$`)
var shard = regexp.MustCompile(`-([0-9]{5})-of-([0-9]{5})\.gguf$`)

func PairingScore(model, auxiliary string) int {
	m := quantization.ReplaceAllString(strings.ToLower(strings.TrimSuffix(filepath.Base(model), filepath.Ext(model))), "")
	a := strings.ToLower(strings.TrimSuffix(filepath.Base(auxiliary), filepath.Ext(auxiliary)))
	// mmproj-模型名稱與模型名稱.mmproj 都保留型號；單純 mmproj-F16 仍沒有可配對身分。
	for _, marker := range []string{"mmproj", "vision-encoder", "projector"} {
		if strings.HasPrefix(a, marker) {
			a = strings.TrimLeft(a[len(marker):], "._- ")
			break
		}
		found := false
		for _, separator := range []string{".", "-", "_"} {
			if i := strings.Index(a, separator+marker); i >= 0 {
				a, found = a[:i], true
				break
			}
		}
		if found {
			break
		}
	}
	a = strings.TrimPrefix(quantization.ReplaceAllString("-"+a, ""), "-")
	if m == "" || a == "" {
		return 0
	}
	if m == a {
		return 100
	}
	if strings.HasPrefix(m, a) || strings.HasPrefix(a, m) {
		return 80
	}
	tokens := func(v string) map[string]bool {
		out := map[string]bool{}
		for _, t := range strings.FieldsFunc(v, func(r rune) bool { return strings.ContainsRune("-_ .", r) }) {
			if len(t) > 1 {
				out[t] = true
			}
		}
		return out
	}
	mt, at := tokens(m), tokens(a)
	shared := 0
	for t := range mt {
		if at[t] {
			shared++
		}
	}
	if shared >= 2 {
		return 20 + shared
	}
	return 0
}
func Paired(model string, candidates []string) (string, error) {
	if len(candidates) == 1 {
		return candidates[0], nil
	}
	sorted := append([]string{}, candidates...)
	sort.Slice(sorted, func(i, j int) bool {
		a, b := PairingScore(model, sorted[i]), PairingScore(model, sorted[j])
		if a != b {
			return a > b
		}
		return sorted[i] < sorted[j]
	})
	if len(sorted) == 0 {
		return "", errors.New("缺少對應的 mmproj 視覺編碼器")
	}
	if PairingScore(model, sorted[0]) == 0 || len(sorted) > 1 && PairingScore(model, sorted[0]) == PairingScore(model, sorted[1]) {
		return "", errors.New("同資料夾有多個 mmproj，無法確定配對")
	}
	return sorted[0], nil
}
func ValidateGGUF(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	header := make([]byte, 24)
	if _, err = io.ReadFull(f, header); err != nil {
		return errors.New("GGUF 檔頭不完整")
	}
	version := binary.LittleEndian.Uint32(header[4:])
	if string(header[:4]) != "GGUF" || (version != 2 && version != 3) {
		return errors.New("不是支援的 GGUF 模型")
	}
	return nil
}
func Scan(ctx context.Context, root string) ([]Entry, error) {
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, err
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return nil, errors.New("模型路徑不是可讀取的目錄")
	}
	primaries := []string{}
	projectors := map[string][]string{}
	mlx := []string{}
	count := 0
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path != root && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			return nil
		}
		count++
		if count > 50000 {
			return errors.New("模型目錄檔案過多，請選取更明確的目錄")
		}
		if d.IsDir() {
			return nil
		}
		if d.Name() == "config.json" {
			mlx = append(mlx, filepath.Dir(path))
		}
		if !strings.EqualFold(filepath.Ext(path), ".gguf") {
			return nil
		}
		if IsProjector(path) {
			projectors[filepath.Dir(path)] = append(projectors[filepath.Dir(path)], path)
		} else {
			if parts := shard.FindStringSubmatch(strings.ToLower(path)); parts != nil && parts[1] != "00001" {
				return nil
			}
			primaries = append(primaries, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	result := []Entry{}
	boundAuxiliary := map[string]bool{}
	for _, p := range primaries {
		if auxiliary, present, e := explicitProjector(p); present && e == nil {
			boundAuxiliary[auxiliary] = true
		}
	}
	for _, p := range primaries {
		if boundAuxiliary[p] {
			continue
		}
		if err = ctx.Err(); err != nil {
			return nil, err
		}
		id, _ := filepath.Rel(root, p)
		entry := Entry{ID: filepath.ToSlash(id), Title: filepath.ToSlash(id), Format: "gguf", Path: p}
		err = ValidateGGUF(p)
		if err == nil {
			if bound, present, e := explicitProjector(p); present {
				entry.Projector, err = bound, e
			} else {
				entry.Projector, err = Paired(p, projectors[filepath.Dir(p)])
			}
		}
		if err == nil {
			err = ValidateGGUF(entry.Projector)
		}
		if err == nil {
			err = validateGGUFShards(p)
		}
		entry.Ready = err == nil
		entry.Message = "可直接使用"
		if err != nil {
			entry.Message = err.Error()
		}
		result = append(result, entry)
	}
	for _, p := range mlx {
		if err = ctx.Err(); err != nil {
			return nil, err
		}
		if !MLXCandidate(p) {
			continue
		}
		id, _ := filepath.Rel(root, filepath.Join(p, "config.json"))
		title, _ := filepath.Rel(root, p)
		if title == "." {
			title = filepath.Base(root)
		}
		entry := Entry{ID: filepath.ToSlash(id), Title: filepath.ToSlash(title), Format: "mlx", Path: p}
		err = ValidateMLX(ctx, p)
		entry.Ready = err == nil
		entry.Message = "MLX 視覺模型，可直接使用"
		if err != nil {
			entry.Message = err.Error()
		}
		result = append(result, entry)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result, nil
}
func validateGGUFShards(path string) error {
	parts := shard.FindStringSubmatch(strings.ToLower(path))
	if parts == nil {
		return nil
	}
	var total int
	_, _ = fmt.Sscan(parts[2], &total)
	if total < 1 || total > 999 {
		return errors.New("GGUF 分片數量不符")
	}
	start := len(path) - len(parts[0])
	for i := 1; i <= total; i++ {
		p := path[:start] + fmt.Sprintf("-%05d-of-%05d.gguf", i, total)
		if err := ValidateGGUF(p); err != nil {
			return fmt.Errorf("模型分片不完整：%s", filepath.Base(p))
		}
	}
	return nil
}

// 舊版的明確配對優先於檔名推測；限定同目錄的一般檔案，禁止越界或 symlink。
func explicitProjector(primary string) (string, bool, error) {
	path := filepath.Join(filepath.Dir(primary), "active-model.json")
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", true, err
	}
	if info.Size() > 65536 {
		return "", true, errors.New("模型配對資料過大")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", true, err
	}
	var binding struct {
		Main      string `json:"mainFileName"`
		Auxiliary string `json:"auxiliaryFileName"`
	}
	if err = json.Unmarshal(data, &binding); err != nil {
		return "", true, errors.New("模型配對資料格式錯誤")
	}
	if binding.Main != filepath.Base(primary) {
		return "", false, nil
	}
	name := binding.Auxiliary
	if name == "" || filepath.Base(name) != name || strings.ContainsAny(name, "/\\") || !strings.EqualFold(filepath.Ext(name), ".gguf") || name == filepath.Base(primary) {
		return "", true, errors.New("輔助模型配對路徑不符")
	}
	target := filepath.Join(filepath.Dir(primary), name)
	info, err = os.Lstat(target)
	if err != nil {
		return "", true, err
	}
	if !info.Mode().IsRegular() {
		return "", true, errors.New("輔助模型必須是同目錄的一般檔案")
	}
	return target, true, ValidateGGUF(target)
}
