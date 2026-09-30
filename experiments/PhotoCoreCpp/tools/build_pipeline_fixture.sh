#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OUTPUT="$ROOT_DIR/build/photocore-cpp"
mkdir -p "$OUTPUT"
# 重新建置來源，避免以過期的 App .o 當參考答案。
swift build --build-system native --package-path "$ROOT_DIR/PhotoStyleShared" --scratch-path "$OUTPUT/shared" -c debug
PRODUCTS="$(swift build --build-system native --package-path "$ROOT_DIR/PhotoStyleShared" --scratch-path "$OUTPUT/shared" -c debug --show-bin-path)"
source "$ROOT_DIR/scripts/webp-test-support.sh"
python3 "$ROOT_DIR/experiments/PhotoCoreCpp/tools/prepare_pipeline_oracle.py" "$ROOT_DIR" "$OUTPUT/oracle-sources"
xcrun swiftc -parse-as-library -swift-version 5 -I "$PRODUCTS/Modules" "${WEBP_SWIFT_FLAGS[@]}" \
  "$ROOT_DIR/PhotoStyleApp/PhotoImage.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoWebPEncoder.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoStyle.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoComputeBackend.swift" \
  "$ROOT_DIR/PhotoStyleApp/Comparable+Clamped.swift" \
  "$OUTPUT/oracle-sources/PhotoStyleProcessor.swift" \
  "$OUTPUT/oracle-sources/PhotoProcessingPipeline.swift" \
  "$ROOT_DIR/PhotoStyleApp/PhotoDateStampRenderer.swift" \
  "$ROOT_DIR/experiments/PhotoCoreCpp/tools/pipeline_fixture.swift" \
  "$PRODUCTS"/PhotoStyleShared.build/*.swift.o -o "$OUTPUT/pipeline-fixture"
