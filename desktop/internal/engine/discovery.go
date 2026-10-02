package engine

import (
	"os"
	"path/filepath"
	"runtime"
)

// 引擎位置依執行檔解析，不依賴使用者啟動程式時的工作目錄。
func DefaultExecutable() string {
	if override := os.Getenv("FILMDEVELOP_ENGINE"); override != "" {
		return override
	}
	executable, _ := os.Executable()
	directory := filepath.Dir(executable)
	if runtime.GOOS == "darwin" {
		worker := filepath.Join("FilmDevelopEngine.app", "Contents", "MacOS", "filmdevelop-engine")
		candidates := []string{filepath.Join(directory, "../Resources/Engine", worker), filepath.Join(directory, "engine-macos", worker)}
		for _, candidate := range candidates {
			if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
				return filepath.Clean(candidate)
			}
		}
		return filepath.Clean(candidates[0])
	}
	return filepath.Join(directory, "engine", "filmdevelop-engine.exe")
}
