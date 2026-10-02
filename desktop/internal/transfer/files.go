// Package transfer 提供下載與匯入共用的暫存、取消、校驗和發布流程。
package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/models"
)

type File struct {
	Path   string `json:"path"`
	URL    string `json:"url"`
	Source string `json:"source,omitempty"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256,omitempty"`
}
type Progress struct {
	FileName       string  `json:"fileName"`
	Received       int64   `json:"received"`
	Total          int64   `json:"total"`
	CompletedFiles int     `json:"completedFiles"`
	TotalFiles     int     `json:"totalFiles"`
	Fraction       float64 `json:"fraction"`
	Percent        int     `json:"percent"`
	Active         bool    `json:"active"`
	IsCancelling   bool    `json:"isCancelling"`
}

var Client = &http.Client{Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, ResponseHeaderTimeout: 30 * time.Second, TLSHandshakeTimeout: 15 * time.Second}, CheckRedirect: func(r *http.Request, via []*http.Request) error {
	if len(via) > 10 {
		return errors.New("下載重新導向過多")
	}
	if via[0].URL.Scheme == "https" && r.URL.Scheme != "https" {
		return errors.New("下載不得降級至不安全的連線")
	}
	return nil
}}

// EnsureManagedDirectory 用於應用程式管理的固定模型快取。損壞的目錄先隔離保留，
// 重新下載失敗時還原；不覆寫連結或把使用者匯入目錄當成可替換快取。
func EnsureManagedDirectory(ctx context.Context, destination string, files []File, progress func(Progress)) error {
	valid := func(directory string) error {
		for _, expected := range files {
			if !models.ValidPath(expected.Path) || expected.SHA256 == "" || expected.Size <= 0 {
				return errors.New("固定模型必須提供路徑、長度及 SHA-256")
			}
			path := filepath.Join(directory, filepath.FromSlash(expected.Path))
			info, err := os.Lstat(path)
			if err != nil || !info.Mode().IsRegular() || info.Size() != expected.Size {
				return errors.New("固定模型檔案不完整")
			}
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			hash := sha256.New()
			_, err = io.Copy(hash, file)
			closeErr := file.Close()
			if err != nil {
				return err
			}
			if closeErr != nil {
				return closeErr
			}
			if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), expected.SHA256) {
				return errors.New("固定模型 SHA-256 不符")
			}
			if err = ctx.Err(); err != nil {
				return err
			}
		}
		return nil
	}
	if len(files) == 0 {
		return errors.New("固定模型清單為空")
	}
	info, err := os.Lstat(destination)
	if errors.Is(err, os.ErrNotExist) {
		return InstallDirectory(ctx, destination, files, valid, progress)
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("固定模型快取不是一般目錄")
	}
	if err = valid(destination); err == nil {
		return nil
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	// 保留損壞內容供診斷，也不會刪除使用者放入快取的額外檔案。
	backup, err := os.MkdirTemp(filepath.Dir(destination), ".filmdevelop-invalid-model-")
	if err != nil {
		return err
	}
	if err = os.Remove(backup); err != nil {
		return err
	}
	if err = os.Rename(destination, backup); err != nil {
		return err
	}
	if err = InstallDirectory(ctx, destination, files, valid, progress); err != nil {
		if restoreErr := os.Rename(backup, destination); restoreErr != nil {
			return fmt.Errorf("%w；舊快取保留於 %s：%v", err, backup, restoreErr)
		}
		return err
	}
	return nil
}

// InstallDirectory 只發布不存在的新目錄；取消或驗證失敗時既有模型完全不變。
func InstallDirectory(ctx context.Context, destination string, files []File, validate func(string) error, progress func(Progress)) error {
	if len(files) == 0 || len(files) > 10000 {
		return errors.New("檔案清單為空或過大")
	}
	seen := map[string]bool{}
	for _, f := range files {
		key := strings.ToLower(f.Path)
		if !models.ValidPath(f.Path) || seen[key] {
			return errors.New("檔案路徑無效或重複")
		}
		seen[key] = true
	}
	if _, e := os.Lstat(destination); e == nil {
		return errors.New("目的目錄已存在")
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	parent := filepath.Dir(destination)
	if e := os.MkdirAll(parent, 0700); e != nil {
		return e
	}
	stage, e := os.MkdirTemp(parent, ".filmdevelop-install-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(stage)
	for i, f := range files {
		if e = ctx.Err(); e != nil {
			return e
		}
		target := filepath.Join(stage, filepath.FromSlash(f.Path))
		if e = os.MkdirAll(filepath.Dir(target), 0700); e != nil {
			return e
		}
		report := func(received, total int64) {
			fraction := 0.0
			if total > 0 {
				fraction = float64(received) / float64(total)
				if fraction > 1 {
					fraction = 1
				}
			}
			fraction = (float64(i) + fraction) / float64(len(files))
			if progress != nil {
				progress(Progress{Active: true, FileName: f.Path, Received: received, Total: total, CompletedFiles: i, TotalFiles: len(files), Fraction: fraction, Percent: int(fraction * 100)})
			}
		}
		if e = copyFile(ctx, f, target, report); e != nil {
			return fmt.Errorf("%s：%w", f.Path, e)
		}
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	if validate != nil {
		if e = validate(stage); e != nil {
			return e
		}
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	// 獨立套件目錄以 rename 原子發布；存在目的地時拒絕覆蓋。
	if _, e = os.Lstat(destination); e == nil {
		return errors.New("目的目錄已存在")
	}
	if e = publishDirectory(stage, destination); e != nil {
		return e
	}
	if progress != nil {
		progress(Progress{Active: true, CompletedFiles: len(files), TotalFiles: len(files), Fraction: 1, Percent: 100})
	}
	return nil
}
func copyFile(ctx context.Context, file File, target string, progress func(int64, int64)) error {
	var input io.ReadCloser
	var original os.FileInfo
	total := file.Size
	if file.Source != "" {
		f, e := os.Open(file.Source)
		if e != nil {
			return e
		}
		info, e := f.Stat()
		if e != nil {
			f.Close()
			return e
		}
		if !info.Mode().IsRegular() {
			f.Close()
			return errors.New("匯入來源不是一般檔案")
		}
		total = info.Size()
		original = info
		input = f
	} else {
		request, e := http.NewRequestWithContext(ctx, http.MethodGet, file.URL, nil)
		if e != nil {
			return e
		}
		response, e := Client.Do(request)
		if e != nil {
			return e
		}
		if response.StatusCode != http.StatusOK {
			response.Body.Close()
			return fmt.Errorf("HTTP %d", response.StatusCode)
		}
		input = response.Body
		if total <= 0 {
			total = response.ContentLength
		}
	}
	defer input.Close()
	output, e := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	defer output.Close()
	hash := sha256.New()
	received := int64(0)
	buffer := make([]byte, 1024*1024)
	last := time.Time{}
	for {
		if e = ctx.Err(); e != nil {
			return e
		}
		n, readErr := input.Read(buffer)
		if n > 0 {
			if _, e = output.Write(buffer[:n]); e != nil {
				return e
			}
			hash.Write(buffer[:n])
			received += int64(n)
			if file.Size > 0 && received > file.Size {
				return errors.New("下載大小超過已查詢的檔案長度")
			}
			if time.Since(last) > 150*time.Millisecond {
				progress(received, total)
				last = time.Now()
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	if original != nil {
		current, err := os.Stat(file.Source)
		if err != nil || !os.SameFile(original, current) || received != original.Size() || original.Size() != current.Size() || !original.ModTime().Equal(current.ModTime()) {
			return errors.New("匯入期間來源檔案已改變")
		}
	}
	if received == 0 || (file.Size > 0 && received != file.Size) {
		return errors.New("檔案下載不完整")
	}
	if file.SHA256 != "" && !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), file.SHA256) {
		return errors.New("檔案校驗碼不符")
	}
	if e = output.Sync(); e != nil {
		return e
	}
	progress(received, received)
	return output.Close()
}
func ReadJSON(ctx context.Context, url string, target any) error { return readJSON(ctx, url, target) }
