//go:build !windows

package main

import (
	"github.com/VaderChen/FilmDevelop/internal/application"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
	"runtime"
)

func configurePlatform(settings *options.App) {
	if runtime.GOOS == "darwin" {
		settings.Mac = &mac.Options{About: &mac.AboutInfo{Title: "FilmDevelop", Message: application.BuildVersion()}, DisableEscapeExitsFullscreen: true}
	}
}
