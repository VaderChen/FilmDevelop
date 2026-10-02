package host

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

type backendProbe struct{ calls, renders int }

func (b *backendProbe) Call(context.Context, string, any, func(float64)) (json.RawMessage, error) {
	b.calls++
	return nil, errors.New("硬體引擎未安裝")
}
func (b *backendProbe) Render(context.Context, contract.RenderJob, func(float64)) (json.RawMessage, error) {
	b.renders++
	return nil, errors.New("硬體引擎未安裝")
}

func TestSharedOperationsWithoutHardware(t *testing.T) {
	backend := &backendProbe{}
	service, err := New(backend)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Catalog(); err != nil {
		t.Fatal(err)
	}
	recipe, err := service.library.Default("filmPortra400")
	if err != nil {
		t.Fatal(err)
	}
	request, _ := json.Marshal(contract.EditorRequest{Recipe: recipe, Changes: json.RawMessage(`[{"key":"printExposure","value":2}]`)})
	response, err := service.Call(context.Background(), "editRecipe", request, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.Call(context.Background(), "normalizeRecipe", response, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = service.Call(context.Background(), "projectRecipes", json.RawMessage(`{"filmPortra400":`+string(response)+`}`), nil); err != nil {
		t.Fatal(err)
	}
	if backend.calls != 0 || backend.renders != 0 {
		t.Fatal("共用操作不應啟動硬體引擎")
	}
	if _, err = service.Render(context.Background(), contract.RenderJob{Recipe: recipe}, nil); err == nil || backend.renders != 1 {
		t.Fatal("渲染未透過共用平台介面")
	}
	recipe.Version = 99
	if _, err = service.Render(context.Background(), contract.RenderJob{Recipe: recipe}, nil); err == nil || backend.renders != 1 {
		t.Fatal("無效配方不應送到硬體引擎")
	}
}

func TestContractRejectsMissingAndUnknownFields(t *testing.T) {
	service, _ := New(&backendProbe{})
	recipe, _ := service.library.Default("original")
	data, _ := json.Marshal(recipe)
	for _, request := range []string{
		strings.Replace(string(data), `"detectSubject":false`, `"extra":false`, 1),
		strings.Replace(string(data), `"detectSubject":false`, `"detectSubject":null`, 1),
		string(data) + ` {}`, `null`,
	} {
		if _, err := service.Call(context.Background(), "normalizeRecipe", json.RawMessage(request), nil); err == nil {
			t.Fatalf("接受不完整契約：%s", request)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := service.Call(ctx, "catalog", nil, nil); !errors.Is(err, context.Canceled) {
		t.Fatal("已取消的操作仍被執行")
	}
}
