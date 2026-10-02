package models

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strings"
)

type HubFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	URL    string `json:"url"`
	SHA256 string `json:"sha256,omitempty"`
}
type Repository struct {
	ID       string    `json:"id"`
	Revision string    `json:"revision"`
	Files    []HubFile `json:"files"`
}
type SearchResult struct {
	ID        string `json:"id"`
	Downloads int64  `json:"downloads"`
	Likes     int64  `json:"likes"`
}
type ReadJSON func(context.Context, string, any) error

const Hub = "https://huggingface.co"

var repositoryID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$`)
var commitID = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)

func ParseRepository(input string) (string, error) {
	v := strings.TrimSpace(input)
	if strings.HasPrefix(v, "https://") {
		u, e := url.Parse(v)
		if e != nil || u.Host != "huggingface.co" || u.User != nil {
			return "", errors.New("請輸入 Hugging Face owner/model")
		}
		v = strings.Trim(u.Path, "/")
	}
	if !repositoryID.MatchString(v) || !ValidPath(v) {
		return "", errors.New("請輸入 Hugging Face owner/model")
	}
	return v, nil
}
func Search(ctx context.Context, read ReadJSON, query, format string) ([]SearchResult, error) {
	if strings.TrimSpace(query) == "" || len(query) > 300 || (format != "gguf" && format != "mlx") {
		return nil, errors.New("模型搜尋條件不符")
	}
	values := url.Values{"search": {query}, "limit": {"50"}, "full": {"true"}}
	var responses []struct {
		ID        string `json:"id"`
		Downloads int64  `json:"downloads"`
		Likes     int64  `json:"likes"`
		Siblings  []struct {
			Path string `json:"rfilename"`
		} `json:"siblings"`
	}
	if err := read(ctx, Hub+"/api/models?"+values.Encode(), &responses); err != nil {
		return nil, err
	}
	results := []SearchResult{}
	seen := map[string]bool{}
	for _, r := range responses {
		if _, err := ParseRepository(r.ID); err != nil || seen[r.ID] {
			continue
		}
		seen[r.ID] = true
		main, config, weights := false, false, false
		for _, s := range r.Siblings {
			if !ValidPath(s.Path) {
				continue
			}
			name := strings.ToLower(s.Path)
			if strings.HasSuffix(name, ".gguf") && !IsProjector(name) {
				main = true
			}
			if name == "config.json" {
				config = true
			}
			if !strings.Contains(name, "/") && strings.HasSuffix(name, ".safetensors") {
				weights = true
			}
		}
		if (format == "gguf" && main) || (format == "mlx" && config && weights) {
			results = append(results, SearchResult{ID: r.ID, Downloads: max(0, r.Downloads), Likes: max(0, r.Likes)})
		}
	}
	return results, nil
}
func Inspect(ctx context.Context, read ReadJSON, input string) (Repository, error) {
	id, e := ParseRepository(input)
	if e != nil {
		return Repository{}, e
	}
	var response struct {
		ID       string `json:"id"`
		SHA      string `json:"sha"`
		Siblings []struct {
			Path string `json:"rfilename"`
			Size int64  `json:"size"`
			LFS  *struct {
				Size int64  `json:"size"`
				SHA  string `json:"sha256"`
			} `json:"lfs"`
		} `json:"siblings"`
	}
	if e = read(ctx, Hub+"/api/models/"+id+"?blobs=true", &response); e != nil {
		return Repository{}, e
	}
	if !commitID.MatchString(response.SHA) {
		return Repository{}, errors.New("模型缺少不可變的版本識別")
	}
	if response.ID != "" {
		if _, e = ParseRepository(response.ID); e != nil {
			return Repository{}, e
		}
		id = response.ID
	}
	r := Repository{ID: id, Revision: response.SHA, Files: []HubFile{}}
	seen := map[string]bool{}
	for _, s := range response.Siblings {
		if !ValidPath(s.Path) {
			continue
		}
		key := strings.ToLower(s.Path)
		if seen[key] {
			return Repository{}, errors.New("模型檔案在 Windows 路徑中重名")
		}
		seen[key] = true
		size := s.Size
		digest := ""
		if s.LFS != nil {
			size = s.LFS.Size
			digest = s.LFS.SHA
		}
		parts := strings.Split(s.Path, "/")
		for i, p := range parts {
			parts[i] = url.PathEscape(p)
		}
		r.Files = append(r.Files, HubFile{Path: s.Path, Size: size, SHA256: digest, URL: Hub + "/" + id + "/resolve/" + response.SHA + "/" + strings.Join(parts, "/")})
	}
	return r, nil
}
func (r Repository) MainFiles() []HubFile {
	out := []HubFile{}
	for _, f := range r.Files {
		if strings.HasSuffix(strings.ToLower(f.Path), ".gguf") && !IsProjector(f.Path) {
			if parts := shard.FindStringSubmatch(strings.ToLower(f.Path)); parts == nil || parts[1] == "00001" {
				out = append(out, f)
			}
		}
	}
	return out
}
func (r Repository) ProjectorFiles() []HubFile {
	out := []HubFile{}
	for _, f := range r.Files {
		if IsProjector(f.Path) {
			out = append(out, f)
		}
	}
	return out
}
func (r Repository) GGUFPlan(main, projector string) ([]HubFile, error) {
	byPath := map[string]HubFile{}
	for _, f := range r.Files {
		byPath[f.Path] = f
	}
	m, ok := byPath[main]
	if !ok || IsProjector(main) || !strings.HasSuffix(strings.ToLower(main), ".gguf") {
		return nil, errors.New("請選取 GGUF 主模型")
	}
	p, ok := byPath[projector]
	if !ok || !IsProjector(projector) {
		return nil, errors.New("請選取對應的 mmproj")
	}
	out := []HubFile{m, p}
	if parts := shard.FindStringSubmatch(strings.ToLower(main)); parts != nil {
		var total int
		_, _ = fmt.Sscan(parts[2], &total)
		if total < 1 || total > 999 {
			return nil, errors.New("分片數量不符")
		}
		out = out[1:]
		stem := main[:len(main)-len(parts[0])]
		for i := 1; i <= total; i++ {
			name := stem + fmt.Sprintf("-%05d-of-%05d.gguf", i, total)
			f, ok := byPath[name]
			if !ok {
				return nil, fmt.Errorf("缺少分片：%s", name)
			}
			out = append(out, f)
		}
	}
	for _, f := range r.Files {
		if documentation(f.Path) {
			out = append(out, f)
		}
	}
	return out, nil
}
func documentation(p string) bool {
	base := strings.ToLower(path.Base(p))
	return strings.HasPrefix(base, "license") || strings.HasPrefix(base, "readme") || strings.HasPrefix(base, "notice") || strings.HasPrefix(base, "copying")
}
func (r Repository) MLXPlan(ctx context.Context, read ReadJSON) ([]HubFile, error) {
	byPath := map[string]HubFile{}
	for _, f := range r.Files {
		byPath[f.Path] = f
	}
	needed := map[string]bool{"config.json": true, "tokenizer.json": true, "tokenizer_config.json": true}
	if _, ok := byPath["preprocessor_config.json"]; ok {
		needed["preprocessor_config.json"] = true
	} else {
		needed["processor_config.json"] = true
	}
	if index, ok := byPath["model.safetensors.index.json"]; ok {
		var parsed struct {
			WeightMap map[string]string `json:"weight_map"`
		}
		if e := read(ctx, index.URL, &parsed); e != nil {
			return nil, e
		}
		if len(parsed.WeightMap) == 0 {
			return nil, errors.New("safetensors 索引缺失")
		}
		needed[index.Path] = true
		for _, p := range parsed.WeightMap {
			if !ValidPath(p) || !strings.HasSuffix(p, ".safetensors") {
				return nil, errors.New("權重索引路徑無效")
			}
			needed[p] = true
		}
	} else {
		needed["model.safetensors"] = true
	}
	assets := strings.Fields("tokenizer.model sentencepiece.bpe.model special_tokens_map.json added_tokens.json vocab.json vocab.txt merges.txt generation_config.json preprocessor_config.json processor_config.json chat_template.json chat_template.jinja")
	for _, f := range r.Files {
		if documentation(f.Path) || (strings.HasPrefix(f.Path, "chat_templates/") && strings.HasSuffix(f.Path, ".jinja")) {
			needed[f.Path] = true
		}
		for _, p := range assets {
			if f.Path == p {
				needed[p] = true
			}
		}
	}
	out := []HubFile{}
	for p := range needed {
		f, ok := byPath[p]
		if !ok {
			return nil, fmt.Errorf("模型缺少必要檔案：%s", p)
		}
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}
