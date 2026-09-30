#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUTPUT="$ROOT/build/photocore-vulkan-full"
ACCESSOR="$ROOT/build/photocore-cpp/shared/arm64-apple-macosx/debug/PhotoStyleShared.build/DerivedSources/resource_bundle_accessor.swift"
if [[ ! -f "$ACCESSOR" ]]; then
  swift build --package-path "$ROOT/PhotoStyleShared" --scratch-path "$ROOT/build/photocore-cpp/shared" -c release
  ACCESSOR="$(find "$ROOT/build/photocore-cpp/shared" -path '*/DerivedSources/resource_bundle_accessor.swift' -print -quit)"
fi
test -f "$ACCESSOR"
mkdir -p "$OUTPUT"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  "$ROOT"/PhotoStyleShared/Sources/PhotoStyleShared/*.swift "$ACCESSOR" \
  "$ROOT/experiments/PhotoCoreCpp/tools/swift_stage_benchmark.swift" \
  -o "$OUTPUT/swift-stage-benchmark"
python3 - "$ROOT" "$OUTPUT" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
root,out=map(Path,sys.argv[1:])
paths=list((root/'PhotoStyleShared/Sources/PhotoStyleShared').glob('*.swift'))+[root/'experiments/PhotoCoreCpp/tools/swift_stage_benchmark.swift']
report={'optimization':'-O','original_swift_sources_unmodified':True,'swift_version':subprocess.check_output(['swift','--version'],text=True).strip(),'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},'binary_sha256':hashlib.sha256((out/'swift-stage-benchmark').read_bytes()).hexdigest()}
(out/'swift-stage-build.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
PY
