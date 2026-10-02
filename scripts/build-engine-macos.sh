#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/require-apple-silicon.sh"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
BUILD="${ENGINE_BUILD_DIR:-$ROOT_DIR/build/engine-macos}"
APP="$BUILD/FilmDevelopEngine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 "$ROOT_DIR/engine/contract/generate.py" --check
if [[ ! -f "$ROOT_DIR/aiTest/ThirdParty/stable-diffusion.cpp/thirdparty/libwebp/src/webp/encode.h" ]]; then
  printf '首次建置：取得影像編碼所需的 libwebp 原始碼…\n'
  git -C "$ROOT_DIR" submodule update --init --recursive -- aiTest/ThirdParty/stable-diffusion.cpp
fi
"$ROOT_DIR/scripts/build-webp-macos.sh"
"$ROOT_DIR/scripts/build-raw-macos.sh"
"$ROOT_DIR/scripts/build-llama-macos.sh"
"$ROOT_DIR/scripts/build-mlx-macos.sh"
swift build --package-path "$ROOT_DIR/PhotoStyleShared" --scratch-path "$BUILD/shared" -c release \
  -Xswiftc -DFILMDEVELOP_BUNDLED_RESOURCES -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=."
PRODUCTS="$(swift build --package-path "$ROOT_DIR/PhotoStyleShared" --scratch-path "$BUILD/shared" -c release --show-bin-path)"
source "$ROOT_DIR/scripts/swift-package-product.sh"
resolve_swift_package_product "$PRODUCTS" PhotoStyleShared
printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>person.vader.FilmDevelop.Engine</string><key>CFBundleExecutable</key><string>filmdevelop-engine</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' > "$APP/Contents/Info.plist"
xcrun swiftc -O -D FILMDEVELOP_GO_HOST -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
  -file-prefix-map "$ROOT_DIR=." -debug-prefix-map "$ROOT_DIR=." -Xlinker -dead_strip \
  -I "$ROOT_DIR/Vendor/llama.cpp/macos/include" -L "$ROOT_DIR/Vendor/llama.cpp/macos/lib" \
  -I "$SWIFT_PRODUCT_MODULES" -I "$ROOT_DIR/Vendor/libwebp/macos/include" \
  -L "$ROOT_DIR/Vendor/libwebp/macos/lib" -lphotowebp \
  -I "$ROOT_DIR/Vendor/PhotoRAW/macos/include" -L "$ROOT_DIR/Vendor/PhotoRAW/macos/lib" \
  "$ROOT_DIR/PhotoStyleApp/PhotoImage.swift" "$ROOT_DIR/PhotoStyleApp/PhotoWebPEncoder.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoStyle.swift" "$ROOT_DIR/PhotoStyleApp/Comparable+Clamped.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoStyleProcessor.swift" "$ROOT_DIR/PhotoStyleApp/PhotoProcessingPipeline.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoComputeBackend.swift" "$ROOT_DIR/PhotoStyleApp/PhotoSoftwareRAWDecoder.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoImageDecoding.swift" "$ROOT_DIR/PhotoStyleApp/PhotoRAWThumbnail.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoDateStampRenderer.swift" "$ROOT_DIR/engine/macos/JSONValue.swift" \
  "$ROOT_DIR/engine/macos/Contract.generated.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoStyleLLMRuntime.swift" "$ROOT_DIR/PhotoStyleApp/PhotoStyleAdjustmentMapper.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoRepairService.swift" \
  "$ROOT_DIR/engine/macos/main.swift" \
  "${SWIFT_PRODUCT_LINK_INPUTS[@]}" -o "$APP/Contents/MacOS/filmdevelop-engine"
# PhotoSharedResources 從封裝資源載入，不依賴 SwiftPM 建置機絕對路徑。
for RESOURCE in "$PRODUCTS"/*.bundle; do
  if [[ -d "$RESOURCE" ]]; then
    # 切換建置系統時同步清除舊 bundle 配置，避免資源重複或載入舊檔。
    rsync -a --delete "$RESOURCE/" "$APP/Contents/Resources/$(basename "$RESOURCE")/"
  fi
done
ditto "$ROOT_DIR/Vendor/PhotoRAW/macos/RAWMapping" "$APP/Contents/Resources/RAWMapping"
ditto "$ROOT_DIR/Vendor/PhotoRAW/macos/RAWLicenses" "$APP/Contents/Resources/RAWLicenses"
if [[ -d "$ROOT_DIR/PhotoStyleApp/Models" ]]; then
  python3 "$ROOT_DIR/scripts/stage-macos-models.py" "$ROOT_DIR/PhotoStyleApp/Models" "$APP/Contents/Resources/Models"
fi
TARGET_BUILD_DIR="$BUILD" CONTENTS_FOLDER_PATH="FilmDevelopEngine.app/Contents" \
  bash "$ROOT_DIR/scripts/build-compute-macos.sh"
ditto "$ROOT_DIR/Vendor/MLXRuntime" "$APP/Contents/Resources/MLX"
# 連結器的 OSO 除錯符號會另外記錄物件檔的絕對路徑；簽章前移除。
xcrun strip -S "$APP/Contents/MacOS/filmdevelop-engine"
codesign --force --sign - "$APP/Contents/MacOS/filmdevelop-engine"
printf '原生引擎已建置：%s\n' "$APP/Contents/MacOS/filmdevelop-engine"
