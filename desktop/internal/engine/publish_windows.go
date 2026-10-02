package engine

import "golang.org/x/sys/windows"

func publish(source, target string) error {
	from, err := windows.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	// 不設定 REPLACE_EXISTING，讓競爭寫入也無法覆蓋已有成品。
	return windows.MoveFileEx(from, to, windows.MOVEFILE_WRITE_THROUGH)
}
