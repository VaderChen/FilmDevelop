//go:build enginesmoke

package application

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/VaderChen/FilmDevelop/internal/mcp"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"net/http"
	"os"
	"path/filepath"
)

// 測試版本只替換作業系統的路徑選擇；前端按鈕及 Go 指令仍走正式流程。
func (a *App) ConfigureDirectorySmoke(path string) {
	a.directoryPicker = func(context.Context, wruntime.OpenDialogOptions) (string, error) { return path, nil }
	a.preferences.Language = "traditionalChinese"
	// 僅測試建置可指定隔離的舊版資料，正式宿主仍使用既有預設路徑。
	if legacy := os.Getenv("FILMDEVELOP_SMOKE_LEGACY_DIR"); legacy != "" && os.Getenv("FILMDEVELOP_DATA_DIR") != "" {
		a.legacyPhotoDirectory = legacy
	}
}

// Smoke 以隨機 loopback 埠呼叫真實 HTTP 端點，不影響使用者原有 MCP 服務。
func (a *App) RunMCPSmoke(ctx context.Context, exportPath string) error {
	server, err := mcp.Start(filepath.Join(filepath.Dir(exportPath), "smoke-mcp"), "127.0.0.1:0", a.mcpDefinitions(), a.handleMCP)
	if err != nil {
		return err
	}
	defer server.Close()
	data, err := os.ReadFile(server.ConnectionFile)
	if err != nil {
		return err
	}
	var config object
	if err = json.Unmarshal(data, &config); err != nil {
		return err
	}
	headers := config["mcpServers"].(object)["FilmYourPhoto"].(object)["headers"].(object)
	call := func(method string, params object) (object, error) {
		body, _ := json.Marshal(object{"jsonrpc": "2.0", "id": identifier(), "method": method, "params": params})
		request, err := http.NewRequestWithContext(ctx, "POST", server.Endpoint, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Authorization", headers["Authorization"].(string))
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		var result object
		if err = json.NewDecoder(response.Body).Decode(&result); err != nil {
			return nil, err
		}
		if result["error"] != nil {
			return nil, fmt.Errorf("MCP RPC 失敗：%v", result["error"])
		}
		value, ok := result["result"].(object)
		if !ok || value["isError"] == true {
			return nil, fmt.Errorf("MCP 工具失敗：%v", value)
		}
		return value, nil
	}
	if _, err = call("initialize", object{"protocolVersion": "2025-11-25"}); err != nil {
		return err
	}
	result, err := call("tools/list", object{})
	if err != nil {
		return err
	}
	if len(result["tools"].([]any)) != 12 {
		return fmt.Errorf("MCP 工具數量不符")
	}
	for _, test := range []struct {
		name string
		args object
	}{
		{"get_state", object{}}, {"list_styles", object{}}, {"show_page", object{"page": "home"}},
		{"set_style", object{"style": "filmGold200"}}, {"update_adjustments", object{"changes": object{"exposure": float64(9), "grain": float64(0)}}},
		{"get_preview", object{}}, {"export_image", object{"path": exportPath, "format": "png", "bitDepth": float64(16)}},
	} {
		if _, err = call("tools/call", object{"name": test.name, "arguments": test.args}); err != nil {
			return fmt.Errorf("%s：%w", test.name, err)
		}
	}
	if info, err := os.Stat(exportPath); err != nil || info.Size() == 0 {
		return fmt.Errorf("MCP 匯出未完成")
	}
	return nil
}
