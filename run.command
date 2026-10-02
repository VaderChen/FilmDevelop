#!/bin/bash
set -euo pipefail

# 從腳本所在位置解析路徑，支援 Finder 與任意工作目錄。
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
cd "$PROJECT_ROOT"
BUILD_LOG="$PROJECT_ROOT/build/run.log"
APP_PATH="$PROJECT_ROOT/build/desktop/FilmDevelopGo.app"

finish() {
  local result=$?
  if [ "$result" -ne 0 ]; then
    printf '\n啟動失敗（代碼 %s），請查看上方錯誤。\n' "$result" >&2
    if [ -t 0 ]; then
      read -r -p '按 Enter 關閉…' reply || true
    fi
  fi
  exit "$result"
}
trap finish EXIT
mkdir -p "$PROJECT_ROOT/build"
printf '正在建置 FilmDevelop：Go 桌面與 Swift／C++ 影像引擎…\n'
bash "$PROJECT_ROOT/scripts/build-desktop-macos.sh" 2>&1 | /usr/bin/tee "$BUILD_LOG"

if [ ! -x "$APP_PATH/Contents/MacOS/FilmDevelopGo" ]; then
  printf '找不到建置產物：%s\n' "$APP_PATH" >&2
  exit 1
fi
/usr/bin/open "$APP_PATH"
printf '\n已開啟 FilmDevelop 混合版本。建置紀錄：%s\n' "$BUILD_LOG"
