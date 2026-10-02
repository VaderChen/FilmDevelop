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
# 只移除封裝副本的舊簽章；路徑調整完成後，再於下方統一簽署。
for LIB in libMoltenVK.dylib libPhotoCompute.dylib; do
  if codesign -d "$CONTENTS/Frameworks/$LIB" >/dev/null 2>&1; then
    codesign --remove-signature "$CONTENTS/Frameworks/$LIB"
  fi
done
# 所有動態依賴以 bundle 內相對路徑解析；不留下開發機 Homebrew 路徑。
MVK_ID="$(otool -D "$PREFIX/lib/libMoltenVK.dylib" | tail -1)"
install_name_tool -id '@rpath/libPhotoCompute.dylib' \
  -change "$MVK_ID" '@loader_path/libMoltenVK.dylib' "$CONTENTS/Frameworks/libPhotoCompute.dylib"
install_name_tool -id '@rpath/libMoltenVK.dylib' "$CONTENTS/Frameworks/libMoltenVK.dylib"
cp "$BUILD/film.comp.spv" "$CONTENTS/Resources/PhotoCompute/"
mkdir -p "$CONTENTS/Resources/PhotoCompute/film-data"
# macOS 的色彩、白平衡與編輯仍由 Swift／Core Image 處理。
# C ABI 僅接收 PhotoComputeStage 的底片運算，不封裝 Windows 專用查表。
rsync -a --delete --delete-excluded --exclude '*.bak' --exclude '.DS_Store' \
  --exclude '/digital-looks/' --exclude '/editor/' \
  "$ROOT/experiments/PhotoCoreCpp/data/" "$CONTENTS/Resources/PhotoCompute/film-data/"
mkdir -p "$CONTENTS/Resources/PhotoCompute/Licenses"
cp "$PREFIX/opt/molten-vk/LICENSE" "$CONTENTS/Resources/PhotoCompute/Licenses/MoltenVK.txt"
cp "$ROOT/experiments/PhotoCoreCpp/third_party/nlohmann/LICENSE" "$CONTENTS/Resources/PhotoCompute/Licenses/nlohmann-json.txt"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "$IDENTITY" ]] || IDENTITY=-
for LIB in libMoltenVK.dylib libPhotoCompute.dylib; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$CONTENTS/Frameworks/$LIB"
done
