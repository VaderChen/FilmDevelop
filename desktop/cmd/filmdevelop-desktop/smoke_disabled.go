//go:build !enginesmoke

package main

import (
	"github.com/VaderChen/FilmDevelop/internal/application"
	"github.com/wailsapp/wails/v2/pkg/options"
)

func configureSmoke(*options.App, *application.App) {}
