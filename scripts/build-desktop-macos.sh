#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
source "$ROOT_DIR/scripts/require-apple-silicon.sh"
for TOOL in go python3 xcrun swift codesign iconutil; do
  command -v "$TOOL" >/dev/null || { printf '缺少桌面建置工具：%s\n' "$TOOL" >&2; exit 1; }
done
if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  printf '需要完整 Xcode，請先選好 Command Line Tools。\n' >&2
  exit 1
fi
APP="$ROOT_DIR/build/desktop/FilmDevelopGo.app"
python3 "$ROOT_DIR/scripts/prepare-desktop.py"
bash "$ROOT_DIR/scripts/build-engine-macos.sh"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Engine"
go -C "$ROOT_DIR/desktop" build -tags desktop,production -o "$APP/Contents/MacOS/FilmDevelopGo" ./cmd/filmdevelop-desktop
python3 "$ROOT_DIR/scripts/macos-bundle.py" "$APP"
ditto "$ROOT_DIR/build/engine-macos/FilmDevelopEngine.app" "$APP/Contents/Resources/Engine/FilmDevelopEngine.app"
python3 "$ROOT_DIR/scripts/collect-desktop-licenses.py" "$APP/Contents/Resources/Licenses/Go"
cp "$ROOT_DIR/LICENSE.md" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/"
cp "$ROOT_DIR/aiTest2/ThirdParty/llama.cpp/LICENSE" "$APP/Contents/Resources/Licenses/llama.cpp-LICENSE"
mkdir -p "$APP/Contents/Resources/Updater"
cp "$ROOT_DIR/PhotoStyleApp/Updater/install.sh" "$APP/Contents/Resources/Updater/install.sh"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'FilmDevelop Go／Swift／C++ 桌面已建置：%s\n' "$APP"
