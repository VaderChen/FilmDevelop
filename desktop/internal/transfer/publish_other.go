//go:build !darwin && !windows && !linux

package transfer

import "errors"

func publishDirectory(string, string) error {
	return errors.New("平台缺少不可覆寫的原子目錄發布")
}
