#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
BUILD="$ROOT/build/photocore-app"
command -v cmake >/dev/null || { echo '需要 CMake 以建置 Vulkan 運算後端。' >&2; exit 1; }
PREFIX="${PHOTO_COMPUTE_PREFIX:-$(brew --prefix)}"
cmake -S "$ROOT/experiments/PhotoCoreCpp" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DPHOTOCORE_VULKAN_APP=ON -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
cmake --build "$BUILD" --target PhotoCompute -j4
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
  CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
else
  CONTENTS="$BUILD/PhotoComputeSmoke.app/Contents"
fi
mkdir -p "$CONTENTS/Frameworks" "$CONTENTS/Resources/PhotoCompute"
cp -f "$BUILD/libPhotoCompute.dylib" "$CONTENTS/Frameworks/"
cp -f "$PREFIX/lib/libMoltenVK.dylib" "$CONTENTS/Frameworks/"
# 所有動態依賴以 bundle 內相對路徑解析；不留下開發機 Homebrew 路徑。
MVK_ID="$(otool -D "$PREFIX/lib/libMoltenVK.dylib" | tail -1)"
install_name_tool -id '@rpath/libPhotoCompute.dylib' \
  -change "$MVK_ID" '@loader_path/libMoltenVK.dylib' "$CONTENTS/Frameworks/libPhotoCompute.dylib"
install_name_tool -id '@rpath/libMoltenVK.dylib' "$CONTENTS/Frameworks/libMoltenVK.dylib"
cp "$BUILD/film.comp.spv" "$CONTENTS/Resources/PhotoCompute/"
mkdir -p "$CONTENTS/Resources/PhotoCompute/film-data"
# 只同步執行資料；修改前的備份與舊建置殘留不得進入 App。
rsync -a --delete --delete-excluded --exclude '*.bak' --exclude '.DS_Store' \
  "$ROOT/experiments/PhotoCoreCpp/data/" "$CONTENTS/Resources/PhotoCompute/film-data/"
mkdir -p "$CONTENTS/Resources/PhotoCompute/Licenses"
cp "$PREFIX/opt/molten-vk/LICENSE" "$CONTENTS/Resources/PhotoCompute/Licenses/MoltenVK.txt"
cp "$ROOT/experiments/PhotoCoreCpp/third_party/nlohmann/LICENSE" "$CONTENTS/Resources/PhotoCompute/Licenses/nlohmann-json.txt"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "$IDENTITY" ]] || IDENTITY=-
for LIB in libMoltenVK.dylib libPhotoCompute.dylib; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$CONTENTS/Frameworks/$LIB"
done
