package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/updater"
)

// 相容入口只完成一次性的安裝移轉，不讀寫照片、設定或模型資料。
func migrate() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	p, err := updater.PrepareIdentityMigration(ctx)
	if err != nil || p == nil {
		return err
	}
	if err = updater.Confirm(os.Args, p.Version); err != nil {
		p.Discard()
		return err
	}
	if err = p.Launch(); err != nil {
		p.Discard()
	}
	return err
}

func main() {
	if err := migrate(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		// 引數直接傳遞，不將路徑或錯誤文字插入 AppleScript 原始碼。
		_ = exec.CommandContext(ctx, "/usr/bin/osascript", "-e",
			"on run argv\n display alert \"FilmDevelop\" message (item 1 of argv)\nend run",
			err.Error()).Run()
		os.Exit(1)
	}
}
