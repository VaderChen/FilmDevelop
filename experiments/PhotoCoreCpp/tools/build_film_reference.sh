#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUTPUT="$ROOT/build/photocore-cpp"
mkdir -p "$OUTPUT"
swift build --package-path "$ROOT/PhotoStyleShared" --scratch-path "$OUTPUT/shared" -c debug
PRODUCTS="$(swift build --package-path "$ROOT/PhotoStyleShared" --scratch-path "$OUTPUT/shared" -c debug --show-bin-path)"
# 只搜尋目前建置系統／組態的來源，避免取得切換前留下的舊 accessor。
DERIVED="$PRODUCTS/PhotoStyleShared.build/DerivedSources"
if [[ ! -d "$DERIVED" ]]; then
  DERIVED="$(dirname "$(dirname "$PRODUCTS")")/Intermediates.noindex/PhotoStyleShared.build/$(basename "$PRODUCTS")"
fi
ACCESSOR="$(find "$DERIVED" -path '*/DerivedSources/resource_bundle_accessor.swift' -print -quit)"
test -n "$ACCESSOR"
python3 - "$ROOT" "$OUTPUT" <<'PYIN'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'PhotoStyleShared/Sources/PhotoStyleShared/PhotoFilmDevelopmentProcessor.swift').read_text()
for anchor in ('        let one = CIImage(', '        let fullRatio = ratio.clampedToExtent()', '        guard let developed = composite.apply'):
    if s.count(anchor)!=1:
        raise RuntimeError('Swift 來源已改變，需重新確認診斷插入位置：'+anchor)
s=s.replace('        let one = CIImage(', '        FilmReference.debugField(active,"field-active")\n        let one = CIImage(')
s=s.replace('        let fullRatio = ratio.clampedToExtent()', '        FilmReference.debugField(salt,"field-salt")\n        FilmReference.debugField(ratio,"field-ratio")\n        let fullRatio = ratio.clampedToExtent()')
s=s.replace('        guard let developed = composite.apply', '        FilmReference.debugField(fullRatio,"field-fullRatio")\n        guard let developed = composite.apply')
(out/'PhotoFilmDevelopmentProcessor-reference.swift').write_text(s)
PYIN
SOURCES=()
for source in "$ROOT"/PhotoStyleShared/Sources/PhotoStyleShared/*.swift; do
  if [[ "$(basename "$source")" == "PhotoFilmDevelopmentProcessor.swift" ]]; then
    SOURCES+=("$OUTPUT/PhotoFilmDevelopmentProcessor-reference.swift")
  else
    SOURCES+=("$source")
  fi
done
xcrun swiftc -parse-as-library -swift-version 5 \
 "${SOURCES[@]}" "$ACCESSOR" \
 "$ROOT/experiments/PhotoCoreCpp/tools/film_reference.swift" -o "$OUTPUT/film-reference"
"$OUTPUT/film-reference" export "$ROOT/experiments/PhotoCoreCpp/data"
python3 - "$ROOT" "$OUTPUT" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
root,output=map(Path,sys.argv[1:])
paths=sorted((root/'PhotoStyleShared/Sources/PhotoStyleShared').glob('*.swift'))
paths+=[root/'experiments/PhotoCoreCpp/tools/film_reference.swift']
fingerprint={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
info={'schema':1,'description':'現有 Swift 原始碼匯出的藝術底片資料；不是外部機身或底片量測資料。',
      'swift_sources_sha256':fingerprint,'swift_version':subprocess.check_output(['swift','--version'],text=True).strip(),
      'assets_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'experiments/PhotoCoreCpp/data').iterdir() if p.suffix in ('.f32','.json') and p.name!='provenance.json'}}
(root/'experiments/PhotoCoreCpp/data/provenance.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
PY
