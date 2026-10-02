package transfer

import "golang.org/x/sys/unix"

func publishDirectory(from, to string) error { return unix.RenamexNp(from, to, unix.RENAME_EXCL) }
