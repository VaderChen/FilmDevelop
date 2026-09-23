#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/scripts/require-apple-silicon.sh"
PACKAGE_ROOT="$PROJECT_ROOT/MLXRuntime"
OUTPUT_ROOT="$PROJECT_ROOT/Vendor/MLXRuntime"
DERIVED_DATA="$PROJECT_ROOT/build/MLXDerivedData"

if ! xcodebuild -version >/dev/null 2>&1; then
  printf '建置 MLX 需要完整 Xcode 與 Metal Toolchain。\n' >&2
  exit 1
fi

fingerprint() {
  {
    printf 'architecture=arm64\ndeployment=14.0\n'
    xcodebuild -version
    shasum -a 256 "$PACKAGE_ROOT/Package.swift" "$PACKAGE_ROOT/README.md" "$PROJECT_ROOT/scripts/build-mlx-macos.sh"
    if [[ -f "$PACKAGE_ROOT/Package.resolved" ]]; then shasum -a 256 "$PACKAGE_ROOT/Package.resolved"; fi
    while IFS= read -r source; do shasum -a 256 "$source"; done < <(find "$PACKAGE_ROOT/Sources" -name '*.swift' -type f | LC_ALL=C sort)
  } | shasum -a 256 | awk '{print $1}'
}
EXPECTED="$(fingerprint)"
if [[ -x "$OUTPUT_ROOT/photostyle-mlx" &&
      -f "$OUTPUT_ROOT/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" &&
      -f "$OUTPUT_ROOT/BUILD_FINGERPRINT" &&
      "$(cat "$OUTPUT_ROOT/BUILD_FINGERPRINT")" == "$EXPECTED" &&
      "$(xcrun lipo -archs "$OUTPUT_ROOT/photostyle-mlx")" == arm64 ]]; then
  printf 'MLX 執行核心已是最新版本。\n'
  exit 0
fi

printf '正在建置 MLX 原生視覺核心（首次建置需要下載 Swift 相依套件）…\n'
cd "$PACKAGE_ROOT"
xcodebuild -scheme PhotoStyleMLXRuntime -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PACKAGE_ROOT/.build" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=14.0 build

PRODUCTS="$DERIVED_DATA/Build/Products/Release"
if [[ ! -x "$PRODUCTS/photostyle-mlx" ||
      ! -f "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  printf 'MLX 建置結果不完整，未更新既有執行核心。\n' >&2
  exit 1
fi
if [[ "$(xcrun lipo -archs "$PRODUCTS/photostyle-mlx")" != arm64 ]]; then
  printf 'MLX 執行核心必須僅包含 arm64。\n' >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT_ROOT")"
STAGING="$(mktemp -d "$(dirname "$OUTPUT_ROOT")/.mlx-staging.XXXXXX")"
cleanup() { [[ ! -d "$STAGING" ]] || rm -rf "$STAGING"; }
trap cleanup EXIT
cp "$PRODUCTS/photostyle-mlx" "$STAGING/photostyle-mlx"
for artifact in "$PRODUCTS"/*.bundle "$PRODUCTS"/*.dylib; do
  [[ ! -e "$artifact" ]] || cp -R "$artifact" "$STAGING/"
done
mkdir -p "$STAGING/Licenses"
for checkout in "$PACKAGE_ROOT/.build/checkouts"/*; do
  [[ -d "$checkout" ]] || continue
  name="$(basename "$checkout")"
  while IFS= read -r -d '' license; do
    relative="${license#"$checkout"/}"
    mkdir -p "$STAGING/Licenses/$name/$(dirname "$relative")"
    cp "$license" "$STAGING/Licenses/$name/$relative"
  done < <(find "$checkout" -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0)
done
cp "$PACKAGE_ROOT/README.md" "$STAGING/README.md"
fingerprint > "$STAGING/BUILD_FINGERPRINT"
# Keep a recoverable previous runtime until the complete replacement is staged.
BACKUP="$PROJECT_ROOT/build/review-mlx-models/backups/runtime.bak"
if [[ -e "$OUTPUT_ROOT" ]]; then
  mkdir -p "$(dirname "$BACKUP")"
  if [[ -e "$BACKUP" ]]; then printf '既有 MLX 備份尚待確認：%s\n' "$BACKUP" >&2; exit 1; fi
  mv "$OUTPUT_ROOT" "$BACKUP"
fi
if ! mv "$STAGING" "$OUTPUT_ROOT"; then
  [[ ! -e "$BACKUP" ]] || mv "$BACKUP" "$OUTPUT_ROOT"
  exit 1
fi
[[ ! -e "$BACKUP" ]] || rm -rf "$BACKUP"
printf 'MLX 執行核心已建立：%s\n' "$OUTPUT_ROOT"
