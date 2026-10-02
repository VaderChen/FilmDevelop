package engine

import "golang.org/x/sys/unix"

func publish(source, target string) error {
	return unix.RenamexNp(source, target, unix.RENAME_EXCL)
}
