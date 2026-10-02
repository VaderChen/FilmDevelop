package engine

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// 預覽專用程序序列處理工作，只保留目前照片的原生解碼與遮罩。
// 取消時丟棄結果並讓 GPU 工作安全收尾；匯出、AI 等工作維持獨立程序。
type previewProcess struct {
	cmd    *exec.Cmd
	input  io.WriteCloser
	output io.ReadCloser
	lines  chan []byte
	stop   chan struct{}
	done   chan struct{}
	err    error
}

func (c *Client) startPreview() (*previewProcess, error) {
	cmd := exec.Command(c.Executable, "--preview-session")
	if c.command != nil {
		cmd = c.command(context.Background())
	}
	configureCommand(cmd)
	cmd.WaitDelay = 5 * time.Second
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	stderr := &limitedLog{}
	cmd.Stderr = stderr
	if err = cmd.Start(); err != nil {
		input.Close()
		stdout.Close()
		return nil, fmt.Errorf("無法啟動預覽引擎：%w", err)
	}
	p := &previewProcess{cmd: cmd, input: input, output: stdout, lines: make(chan []byte), stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(p.done)
		defer close(p.lines)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 65536), contract.MaxMessageBytes)
		for scanner.Scan() {
			select {
			case p.lines <- bytes.Clone(scanner.Bytes()):
			case <-p.stop:
				_ = cmd.Process.Kill()
			}
		}
		p.err = scanner.Err()
		if p.err != nil {
			_ = cmd.Process.Kill()
		}
		if err := cmd.Wait(); err != nil && p.err == nil {
			p.err = fmt.Errorf("預覽引擎中止：%w；%s", err, stderr.String())
		}
	}()
	return p, nil
}

// 呼叫方持有 gate。停止後所有讀取、寫入與程序資源皆已收回。
func (c *Client) closePreview() {
	if c.previewIdle != nil {
		c.previewIdle.Stop()
		c.previewIdle = nil
	}
	if p := c.preview; p != nil {
		c.preview = nil
		close(p.stop)
		_ = p.input.Close()
		select {
		case <-p.done:
		case <-time.After(3 * time.Second):
			_ = p.cmd.Process.Kill()
			_ = p.output.Close()
			<-p.done
		}
	}
}

func (c *Client) Close() error {
	c.gate <- struct{}{}
	defer func() { <-c.gate }()
	c.closePreview()
	return nil
}

func (c *Client) callPreview(ctx context.Context, id string, request []byte, progress func(float64)) (result json.RawMessage, failure error) {
	if c.previewIdle != nil {
		c.previewIdle.Stop()
		c.previewIdle = nil
	}
	if c.preview != nil {
		select {
		case <-c.preview.done:
			c.closePreview()
		default:
		}
	}
	if c.preview == nil {
		var err error
		c.preview, err = c.startPreview()
		if err != nil {
			return nil, err
		}
	}
	p := c.preview
	// 與原 Swift 排程相同，過期結果不發布，保留完成中的 GPU 工作與解碼快取。
	// 避免在 Metal 更新磁碟快取鎖時強制退出；只對無法收尾的程序限時回收。
	watchDone, cancelDone := make(chan struct{}), make(chan struct{})
	completed := false
	go func() {
		defer close(cancelDone)
		select {
		case <-watchDone:
			return
		case <-ctx.Done():
		}
		timer := time.NewTimer(30 * time.Second)
		defer timer.Stop()
		select {
		case <-watchDone:
		case <-timer.C:
			_ = p.cmd.Process.Kill()
			_ = p.output.Close()
		}
	}()
	defer func() {
		close(watchDone)
		<-cancelDone
		if ctx.Err() != nil {
			result = nil
			failure = ctx.Err()
		}
		if failure != nil && !completed {
			c.closePreview()
			return
		}
		c.previewIdle = time.AfterFunc(45*time.Second, func() {
			select {
			case c.gate <- struct{}{}:
				defer func() { <-c.gate }()
				if c.preview == p {
					c.closePreview()
				}
			default:
			}
		})
	}()
	if _, err := p.input.Write(request); err != nil {
		return nil, err
	}
	for {
		select {
		case line, ok := <-p.lines:
			if !ok {
				<-p.done
				if p.err != nil {
					return nil, p.err
				}
				return nil, errors.New("預覽引擎未回傳完成結果")
			}
			var response contract.Response
			decoder := json.NewDecoder(bytes.NewReader(line))
			decoder.DisallowUnknownFields()
			if decoder.Decode(&response) != nil || decoder.Decode(new(any)) != io.EOF || response.ID != id || response.Version != contract.Version {
				return nil, errors.New("預覽引擎回覆格式或工作識別不符")
			}
			switch response.Kind {
			case "progress":
				var fraction float64
				if json.Unmarshal(response.Payload, &fraction) != nil || fraction < 0 || fraction > 1 || response.Error != nil || bytes.Equal(response.Payload, []byte("null")) {
					return nil, errors.New("預覽引擎進度格式錯誤")
				}
				if progress != nil && ctx.Err() == nil {
					progress(fraction)
				}
			case "result":
				if response.Error != nil || len(response.Payload) == 0 || bytes.Equal(response.Payload, []byte("null")) {
					return nil, errors.New("預覽完成回覆不可包含錯誤")
				}
				completed = true
				return response.Payload, nil
			case "error":
				if response.Error == nil {
					return nil, errors.New("預覽錯誤回覆缺少原因")
				}
				return nil, &NativeError{Code: response.Error.Code, Message: response.Error.Message}
			default:
				return nil, errors.New("預覽引擎回覆類型不支援")
			}
		}
	}
}
