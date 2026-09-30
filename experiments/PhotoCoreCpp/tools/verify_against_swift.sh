#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/build/photocore-cpp}"
PRODUCTS="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}/Build/Products/Debug"
mkdir -p "$OUTPUT_DIR"
if [[ ! -f "$PRODUCTS/PhotoStyleShared.o" ]]; then
  printf '請先建置現有 macOS Debug 版，以取得未修改的 PhotoStyleShared 參考模組。\n' >&2
  exit 1
fi
xcrun swiftc -swift-version 5 -I "$PRODUCTS" \
  "$ROOT_DIR/PhotoStyleShared/Sources/PhotoStyleShared/PhotoExposureProtection.swift" \
  "$ROOT_DIR/PhotoStyleShared/Sources/PhotoStyleShared/PhotoExposureColor.swift" \
  "$ROOT_DIR/PhotoStyleShared/Sources/PhotoStyleShared/PhotoExposureScale.swift" \
  "$ROOT_DIR/experiments/PhotoCoreCpp/tools/swift_reference.swift" \
  "$PRODUCTS/PhotoStyleShared.o" -o "$OUTPUT_DIR/swift-reference"
"$OUTPUT_DIR/swift-reference" "$OUTPUT_DIR/swift-reference.txt"
"$OUTPUT_DIR/photo_core_verify" "$OUTPUT_DIR/swift-reference.txt"
