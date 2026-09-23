#!/bin/bash
set -euo pipefail

# Resolve paths from this file so Finder and other working directories both work.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/scripts/require-apple-silicon.sh"
cd "$PROJECT_ROOT"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_ROOT/build/DerivedData}"
BUILD_LOG="$PROJECT_ROOT/build/run.log"

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

if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  printf '需要完整 Xcode；請先在 Xcode 設定中選好 Command Line Tools。\n' >&2
  exit 1
fi

"$PROJECT_ROOT/scripts/build-llama-macos.sh"
"$PROJECT_ROOT/scripts/build-webp-macos.sh"
"$PROJECT_ROOT/scripts/build-mlx-macos.sh"

mkdir -p "$PROJECT_ROOT/build"
printf '正在建置照片沖洗，完成後會自動開啟…\n'
/usr/bin/xcodebuild -quiet \
  -project "$PROJECT_ROOT/PhotoStyleApp.xcodeproj" \
  -scheme PhotoStyleApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | /usr/bin/tee "$BUILD_LOG"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/PhotoStyleApp.app"
if [ ! -d "$APP_PATH" ]; then
  printf '找不到建置產物：%s\n' "$APP_PATH" >&2
  exit 1
fi
/usr/bin/open "$APP_PATH"
printf '\n已開啟照片沖洗。建置紀錄：%s\n' "$BUILD_LOG"
