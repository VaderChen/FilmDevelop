// Package engine 管理原生程序生命週期；像素運算留在 Swift／C++。
package engine

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/exifmeta"
)

type Client struct {
	Executable     string
	gate           chan struct{}
	command        func(context.Context) *exec.Cmd
	preview        *previewProcess
	previewIdle    *time.Timer
	previewSource  *previewSource
	rawConversions *rawConversionCache
}

func New(executable string) *Client {
	return &Client{Executable: executable, gate: make(chan struct{}, 1)}
}

type NativeError struct{ Code, Message string }

func (e *NativeError) Error() string { return e.Code + ": " + e.Message }

type limitedLog struct{ bytes.Buffer }

func (l *limitedLog) Write(data []byte) (int, error) {
	n := len(data)
	if remaining := 65536 - l.Len(); remaining > 0 {
		if len(data) > remaining {
			data = data[:remaining]
		}
		_, _ = l.Buffer.Write(data)
	}
	return n, nil
}

func (c *Client) Call(ctx context.Context, method string, value any, progress func(float64)) (json.RawMessage, error) {
	select {
	case c.gate <- struct{}{}:
		defer func() { <-c.gate }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	return c.callLocked(ctx, method, value, progress)
}

// 呼叫方持有 gate；來源快照與原生解碼快取在同一個序列中更新。
func (c *Client) callLocked(ctx context.Context, method string, value any, progress func(float64)) (json.RawMessage, error) {
	return c.callWithRAWConversion(ctx, method, value, progress)
}

func (c *Client) callNativeLocked(ctx context.Context, method string, value any, progress func(float64)) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if method == "infer" {
		if request, ok := value.(contract.InferenceRequest); ok && request.Format == "mlx" {
			// MLX 舊版只回報開始生成與套用預覽兩個階段，沿用相同語意。
			if progress != nil {
				progress(1.0 / 7)
			}
			result, err := c.inferMLX(ctx, request)
			if err == nil && progress != nil {
				progress(6.0 / 7)
			}
			return result, err
		}
	}
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return nil, err
	}
	payload, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	id := hex.EncodeToString(token[:])
	request, err := json.Marshal(contract.Request{Version: contract.Version, ID: id, Method: method, Payload: payload})
	if err != nil {
		return nil, err
	}
	if len(request)+1 > contract.MaxMessageBytes {
		return nil, errors.New("引擎請求超過大小限制")
	}
	if method == "preview" {
		return c.callPreview(ctx, id, append(request, '\n'), progress)
	}
	cmd := exec.CommandContext(ctx, c.Executable)
	if c.command != nil {
		cmd = c.command(ctx)
	}
	configureCommand(cmd)
	cmd.WaitDelay = 5 * time.Second
	cmd.Stdin = bytes.NewReader(append(request, '\n'))
	var stderr limitedLog
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		return nil, fmt.Errorf("無法啟動原生引擎：%w", err)
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 65536), contract.MaxMessageBytes)
	var result json.RawMessage
	var failure error
	terminal := false
	for scanner.Scan() {
		var response contract.Response
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.DisallowUnknownFields()
		if err = decoder.Decode(&response); err != nil || decoder.Decode(new(any)) != io.EOF || response.ID != id || response.Version != contract.Version || terminal {
			failure = errors.New("原生引擎回覆格式、工作 ID 或順序不符")
			break
		}
		switch response.Kind {
		case "progress":
			var fraction float64
			if err = json.Unmarshal(response.Payload, &fraction); err != nil || fraction < 0 || fraction > 1 || response.Error != nil || bytes.Equal(response.Payload, []byte("null")) {
				failure = errors.New("原生引擎進度格式錯誤")
			} else if progress != nil {
				progress(fraction)
			}
		case "result":
			if response.Error != nil || len(response.Payload) == 0 || bytes.Equal(response.Payload, []byte("null")) {
				failure = errors.New("完成回覆不可包含錯誤")
				break
			}
			terminal = true
			result = response.Payload
		case "error":
			terminal = true
			if response.Error == nil {
				failure = errors.New("原生引擎錯誤回覆缺少原因")
			} else {
				failure = &NativeError{Code: response.Error.Code, Message: response.Error.Message}
			}
		default:
			failure = errors.New("原生引擎回覆類型不支援")
		}
		if failure != nil {
			break
		}
	}
	if failure == nil {
		failure = scanner.Err()
	}
	if failure != nil {
		_ = cmd.Process.Kill()
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if failure != nil {
		return nil, failure
	}
	if waitErr != nil {
		return nil, fmt.Errorf("原生引擎中止：%w；%s", waitErr, strings.TrimSpace(stderr.String()))
	}
	if !terminal || len(result) == 0 {
		return nil, errors.New("原生引擎未回傳完成結果")
	}
	return result, nil
}

// Render 先建立來源快照。引擎只寫暫存檔；工作成功才以不可覆寫的方式發布。
func (c *Client) Render(ctx context.Context, job contract.RenderJob, progress func(float64)) (json.RawMessage, error) {
	return c.render(ctx, job, progress, nil)
}

func (c *Client) RenderWithStages(ctx context.Context, job contract.RenderJob, stages func(string, float64)) (json.RawMessage, error) {
	return c.render(ctx, job, nil, stages)
}

func (c *Client) render(ctx context.Context, job contract.RenderJob, progress func(float64), stages func(string, float64)) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	input, err := filepath.Abs(job.Input.Path)
	if err != nil {
		return nil, err
	}
	target, err := filepath.Abs(job.Output.Path)
	if err != nil {
		return nil, err
	}
	if input == target {
		return nil, errors.New("匯出不可覆蓋原始照片")
	}
	if _, err := os.Lstat(target); err == nil {
		return nil, errors.New("匯出檔案已存在，請選擇另一個名稱")
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	work, err := os.MkdirTemp(filepath.Dir(target), ".filmdevelop-work-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)
	snapshot := filepath.Join(work, "source"+filepath.Ext(input))
	var fingerprint io.Writer
	digest := sha256.New()
	if job.Preview {
		fingerprint = digest
	}
	if err := copySnapshot(ctx, input, snapshot, fingerprint); err != nil {
		return nil, err
	}
	job.Input.Path = snapshot
	job.Output.Path = filepath.Join(work, "result."+job.Output.Format)
	writeExif := !job.Preview && job.Output.WriteExif != nil && *job.Output.WriteExif
	// EXIF 屬於 Go 的檔案處理；原生程序只接收像素輸出設定，亦相容既有引擎。
	job.Output.WriteExif = nil
	report := func(stage string, value float64) {
		if stages != nil {
			stages(stage, value)
		}
	}
	if stages != nil {
		encoding := false
		progress = func(value float64) {
			report("render", value)
			if value >= 1 && !encoding {
				encoding = true
				report("encode", 0)
			}
		}
	}
	report("render", 0)
	var result json.RawMessage
	if job.Preview {
		result, err = c.renderPreview(ctx, job, hex.EncodeToString(digest.Sum(nil)), progress)
	} else {
		result, err = c.Call(ctx, "render", job, progress)
	}
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	report("encode", 1)
	report("write", 0)
	if writeExif {
		metadata, err := exifmeta.Read(ctx, snapshot)
		if err != nil {
			return nil, err
		}
		if metadata.NeedsFallback() {
			if data, nativeErr := c.Call(ctx, "metadata", contract.FileRequest{Path: snapshot}, nil); nativeErr == nil {
				var properties map[string]any
				if json.Unmarshal(data, &properties) == nil {
					metadata.FillProperties(properties)
				}
			}
		}
		var dimensions struct{ Width, Height int }
		if err := json.Unmarshal(result, &dimensions); err != nil {
			return nil, err
		}
		if err := exifmeta.Write(ctx, job.Output.Path, job.Output.Format, job.Output.ColorSpace, dimensions.Width, dimensions.Height, metadata); err != nil {
			return nil, fmt.Errorf("寫入 EXIF 失敗：%w", err)
		}
	}
	file, err := os.OpenFile(job.Output.Path, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("原生引擎未產生成品：%w", err)
	}
	info, statErr := file.Stat()
	syncErr := file.Sync()
	_ = file.Close()
	if statErr != nil {
		return nil, statErr
	}
	if syncErr != nil {
		return nil, fmt.Errorf("同步匯出檔案失敗：%w", syncErr)
	}
	if !info.Mode().IsRegular() || info.Size() == 0 {
		return nil, errors.New("原生引擎成品為空或格式不符")
	}
	if writeExif {
		var fields map[string]any
		if json.Unmarshal(result, &fields) == nil && fields != nil {
			fields["bytes"] = info.Size()
			result, err = json.Marshal(fields)
			if err != nil {
				return nil, err
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// 使用平台提供的不可覆寫移動，亦支援不提供硬連結的外接磁碟。
	if err := publish(job.Output.Path, target); err != nil {
		return nil, fmt.Errorf("發布成品失敗：%w", err)
	}
	report("write", 1)
	return result, nil
}

func copySnapshot(ctx context.Context, source, target string, fingerprint io.Writer) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	before, err := input.Stat()
	if err != nil {
		return err
	}
	if !before.Mode().IsRegular() {
		return errors.New("來源必須為一般影像檔案")
	}
	output, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer output.Close()
	buffer := make([]byte, 1024*1024)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		n, readErr := input.Read(buffer)
		if n > 0 {
			if _, err := output.Write(buffer[:n]); err != nil {
				return err
			}
			if fingerprint != nil {
				if _, err := fingerprint.Write(buffer[:n]); err != nil {
					return err
				}
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	after, err := input.Stat()
	if err != nil {
		return err
	}
	if before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return errors.New("來源在讀取時已變更，請重試")
	}
	return output.Close()
}
