package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// MLX 保留既有硬體工作程序的窄介面；Go 轉接為兩平台共用的推論契約。
func (c *Client) inferMLX(ctx context.Context, value contract.InferenceRequest) (json.RawMessage, error) {
	if value.MaxTokens < 1 || value.MaxTokens > 4096 || value.ContextLimit < 4096 || value.ContextLimit > 16384 {
		return nil, errors.New("MLX 推論參數無效")
	}
	request := map[string]any{"modelDirectory": value.ModelPath, "systemPrompt": value.SystemPrompt, "userPrompt": strings.ReplaceAll(value.UserPrompt, "<image>\n", ""), "imageBase64": value.ImageData, "maxTokens": value.MaxTokens, "contextLimit": value.ContextLimit}
	data, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if len(data) > contract.MaxMessageBytes {
		return nil, errors.New("MLX 請求過大")
	}
	binary := filepath.Join(filepath.Dir(filepath.Dir(c.Executable)), "Resources", "MLX", "photostyle-mlx")
	cmd := exec.CommandContext(ctx, binary)
	configureCommand(cmd)
	cmd.WaitDelay = 5 * time.Second
	cmd.Stdin = bytes.NewReader(data)
	var stderr limitedLog
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	output, readErr := io.ReadAll(io.LimitReader(stdout, 128*1024+1))
	if readErr != nil || len(output) > 128*1024 {
		_ = cmd.Process.Kill()
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if readErr != nil {
		return nil, readErr
	}
	if len(output) > 128*1024 {
		return nil, errors.New("MLX 輸出過長")
	}
	var response struct {
		Text  string `json:"text"`
		Error string `json:"error"`
	}
	decoder := json.NewDecoder(bytes.NewReader(output))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&response); err != nil || decoder.Decode(new(any)) != io.EOF {
		return nil, fmt.Errorf("MLX 回覆格式不符：%s", stderr.String())
	}
	if response.Error != "" {
		return nil, errors.New(response.Error)
	}
	if waitErr != nil {
		return nil, fmt.Errorf("MLX 推論中止：%w；%s", waitErr, stderr.String())
	}
	if strings.TrimSpace(response.Text) == "" {
		return nil, errors.New("MLX 未產生回應")
	}
	return json.Marshal(map[string]string{"text": response.Text})
}
