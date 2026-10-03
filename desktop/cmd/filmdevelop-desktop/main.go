package main

import (
	"fmt"
	"os"

	"github.com/VaderChen/FilmDevelop/frontend"
	"github.com/VaderChen/FilmDevelop/internal/application"
	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

func main() {
	assets := frontend.Assets()
	app, err := application.New(engine.DefaultExecutable())
	if err != nil {
		panic(err)
	}
	settings := &options.App{Title: "FilmDevelop", Width: 1380, Height: 900, MinWidth: 1050, MinHeight: 700,
		DragAndDrop: &options.DragAndDrop{EnableFileDrop: true, DisableWebViewDrop: true},
		AssetServer: &assetserver.Options{Assets: assets}, OnStartup: app.Startup, OnShutdown: app.Shutdown, OnBeforeClose: app.BeforeClose}
	configurePlatform(settings)
	settings.Menu = app.Menu()
	if settings.Mac != nil {
		settings.Mac.OnFileOpen = app.OpenFileFromOS
	}
	configureSmoke(settings, app)
	err = wails.Run(settings)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
