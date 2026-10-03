package engine

import (
	"io"
	"os"
)

// 使用有界串流發布，不支援原子不可覆寫移動的檔案系統也不得覆蓋既有檔案。
func publishCopy(source, target string) (err error) {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	created, err := output.Stat()
	defer func() {
		if closeErr := output.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			if current, statErr := os.Lstat(target); statErr == nil && created != nil && os.SameFile(created, current) {
				_ = os.Remove(target)
			}
		}
	}()
	if err != nil {
		return err
	}
	if _, err = io.Copy(output, input); err != nil {
		return err
	}
	return output.Sync()
}
