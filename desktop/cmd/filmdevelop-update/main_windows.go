package main

import (
	"context"
	"fmt"
	"os"

	"github.com/VaderChen/FilmDevelop/internal/updater"
)

func main() {
	var err error
	switch {
	case len(os.Args) == 3 && os.Args[1] == "--apply":
		err = updater.RunWindowsUpdate(os.Args[2])
	case len(os.Args) == 5 && os.Args[1] == "--verify":
		err = updater.VerifyWindowsArchive(context.Background(), os.Args[2], updater.Version{Version: os.Args[3], Build: os.Args[4]})
	default:
		err = fmt.Errorf("此工具由 FilmDevelop 的更新流程啟動")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Windows ZIP 驗證／更新完成")
}
