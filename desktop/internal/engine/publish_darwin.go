package engine

import (
	"errors"
	"golang.org/x/sys/unix"
)

func publish(source, target string) error {
	return publishDarwin(source, target, unix.RenamexNp)
}

func publishDarwin(source, target string, rename func(string, string, uint32) error) error {
	err := rename(source, target, unix.RENAME_EXCL)
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.ENOSYS) || errors.Is(err, unix.EINVAL) {
		// 部分外接／網路檔案系統不支援 RENAME_EXCL；仍以 O_EXCL 保證不覆寫。
		return publishCopy(source, target)
	}
	return err
}
