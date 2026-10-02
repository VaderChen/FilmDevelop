//go:build !windows

package photos

import "os"

func hidden(os.FileInfo) bool { return false }
