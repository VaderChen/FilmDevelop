package frontend

import (
	"embed"
	"io/fs"
)

//go:embed dist/*
var files embed.FS

func Assets() fs.FS {
	assets, err := fs.Sub(files, "dist")
	if err != nil {
		panic(err)
	}
	return assets
}
