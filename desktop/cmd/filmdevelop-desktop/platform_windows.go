package main

import (
	"path/filepath"

	"github.com/VaderChen/FilmDevelop/internal/storage"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

func configurePlatform(settings *options.App) {
	root, err := storage.DataDirectory()
	if err != nil {
		panic(err)
	}
	messages := windows.DefaultMessages()
	messages.InstallationRequired = "FilmDevelop 需要 Microsoft Edge WebView2 Runtime。按「確定」下載並安裝，過程需要網路連線。"
	messages.UpdateRequired = "WebView2 Runtime 需要更新。按「確定」下載並安裝，過程需要網路連線。"
	messages.MissingRequirements = "FilmDevelop 執行環境"
	messages.Webview2NotInstalled = "尚未安裝 WebView2 Runtime"
	messages.FailedToInstall = "WebView2 Runtime 安裝未完成，請確認網路或由系統管理員安裝後重試。"
	messages.Error = "FilmDevelop 啟動失敗"
	messages.DownloadPage = "FilmDevelop 需要 WebView2 Runtime。按「確定」開啟下載頁面。最低版本："
	messages.PressOKToInstall = "按「確定」安裝。"
	messages.ContactAdmin = "FilmDevelop 需要 WebView2 Runtime，請聯絡系統管理員安裝。"
	messages.InvalidFixedWebview2 = "指定的 WebView2 Runtime 無效，請確認路徑與版本。"
	messages.WebView2ProcessCrash = "WebView2 程序已停止，請重新啟動 FilmDevelop。"
	settings.Windows = &windows.Options{WebviewUserDataPath: filepath.Join(root, "WebView2"), Messages: messages}
}
