package main

// Wails 的原生選檔器使用 UTType，明確宣告連結所需的系統框架。

// #cgo LDFLAGS: -framework UniformTypeIdentifiers
import "C"
