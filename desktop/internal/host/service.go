// Package host 是 UI 與平台引擎之間的共用中介層。
// 配方由 Go 處理；原生介面只負責能力查詢及影像工作。
package host

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/recipes"
)

// Backend 由同一個 JSONL 程序轉接器實作。macOS 使用 Swift，Windows 使用 C++。
// 實作必須等待取消的工作退出，且只在成功時發布成品。
type Backend interface {
	Call(context.Context, string, any, func(float64)) (json.RawMessage, error)
	Render(context.Context, contract.RenderJob, func(float64)) (json.RawMessage, error)
}

type Service struct {
	backend Backend
	library *recipes.Library
}

func New(backend Backend) (*Service, error) {
	library, err := recipes.New()
	if err != nil {
		return nil, err
	}
	return &Service{backend: backend, library: library}, nil
}

func (s *Service) Catalog() (json.RawMessage, error) { return s.library.Catalog() }
func (s *Service) Close() error {
	if closer, ok := s.backend.(io.Closer); ok {
		return closer.Close()
	}
	return nil
}
func (s *Service) NormalizeRecipe(recipe contract.Recipe) (contract.Recipe, error) {
	return s.library.Normalize(recipe)
}
func (s *Service) EditRecipe(request contract.EditorRequest) (contract.Recipe, error) {
	return s.library.Edit(request)
}
func (s *Service) ProjectRecipes(values map[string]contract.Recipe) (map[string]map[string]any, error) {
	return s.library.ProjectMany(values)
}

func (s *Service) Render(ctx context.Context, job contract.RenderJob, progress func(float64)) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := s.library.Validate(job.Recipe); err != nil {
		return nil, err
	}
	return s.backend.Render(ctx, job, progress)
}

func (s *Service) RenderWithStages(ctx context.Context, job contract.RenderJob, progress func(string, float64)) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := s.library.Validate(job.Recipe); err != nil {
		return nil, err
	}
	if backend, ok := s.backend.(interface {
		RenderWithStages(context.Context, contract.RenderJob, func(string, float64)) (json.RawMessage, error)
	}); ok {
		return backend.RenderWithStages(ctx, job, progress)
	}
	return s.backend.Render(ctx, job, func(value float64) {
		if progress != nil {
			progress("render", value)
		}
	})
}

// Native 僅用於平台計算及硬體介面；檔案和應用狀態仍由 Go 管理。
func (s *Service) Native(ctx context.Context, method string, value any, progress func(float64)) (json.RawMessage, error) {
	return s.backend.Call(ctx, method, value, progress)
}

func (s *Service) Thumbnail(ctx context.Context, path string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	data, err := s.backend.Call(ctx, "thumbnail", contract.ThumbnailRequest{Path: path, MaxPixel: 256}, nil)
	if err != nil {
		return nil, err
	}
	var result contract.ThumbnailResult
	if err := strictDecode(data, &result); err != nil {
		return nil, err
	}
	image, err := base64.StdEncoding.DecodeString(result.ImageData)
	if err != nil || !photos.ValidThumbnail(image) || result.Width < 1 || result.Height < 1 || result.Width > 256 || result.Height > 256 {
		return nil, errors.New("原生縮圖格式或大小不符")
	}
	return photos.NormalizeThumbnail(path, image), nil
}

// Call 供 CLI／自動化共用；桌面程式使用上方具型別的介面。
func (s *Service) Call(ctx context.Context, method string, input json.RawMessage, progress func(float64)) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(input) > contract.MaxMessageBytes {
		return nil, errors.New("請求超過大小限制")
	}
	switch method {
	case "catalog":
		return s.Catalog()
	case "normalizeRecipe":
		var request contract.Recipe
		if err := strictDecode(input, &request); err != nil {
			return nil, err
		}
		result, err := s.NormalizeRecipe(request)
		if err != nil {
			return nil, err
		}
		return json.Marshal(result)
	case "editRecipe":
		var request contract.EditorRequest
		if err := strictDecode(input, &request); err != nil {
			return nil, err
		}
		result, err := s.EditRecipe(request)
		if err != nil {
			return nil, err
		}
		return json.Marshal(result)
	case "projectRecipes":
		var request map[string]contract.Recipe
		if err := strictDecode(input, &request); err != nil {
			return nil, err
		}
		if request == nil {
			return nil, errors.New("配方投影需要物件")
		}
		result, err := s.ProjectRecipes(request)
		if err != nil {
			return nil, err
		}
		return json.Marshal(result)
	case "render", "preview":
		var request contract.RenderJob
		if err := strictDecode(input, &request); err != nil {
			return nil, err
		}
		if method == "preview" && !request.Preview {
			return nil, errors.New("預覽介面不得用於匯出")
		}
		return s.Render(ctx, request, progress)
	case "capabilities":
		return s.backend.Call(ctx, method, input, progress)
	default:
		return nil, fmt.Errorf("不支援的宿主操作：%s", method)
	}
}

func strictDecode(data json.RawMessage, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return errors.New("請求包含多餘 JSON")
	}
	encoded, err := json.Marshal(target)
	if err != nil {
		return err
	}
	var actual, canonical any
	if err := json.Unmarshal(data, &actual); err != nil {
		return err
	}
	if err := json.Unmarshal(encoded, &canonical); err != nil {
		return err
	}
	if !reflect.DeepEqual(actual, canonical) {
		return errors.New("請求缺少必要欄位或欄位型別不符")
	}
	return nil
}

func (s *Service) MapPlan(text string, base contract.Recipe) (contract.Recipe, error) {
	return s.library.MapPlan(text, base)
}
func (s *Service) EditorProperties() map[string]any { return s.library.EditorProperties() }
