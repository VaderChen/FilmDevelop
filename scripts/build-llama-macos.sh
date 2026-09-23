#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/require-apple-silicon.sh"
SOURCE_DIR="${LLAMA_SOURCE_DIR:-$ROOT_DIR/aiTest2/ThirdParty/llama.cpp}"
OUTPUT_DIR="$ROOT_DIR/Vendor/llama.cpp/macos"
BUILD_DIR="${LLAMA_BUILD_DIR:-$ROOT_DIR/.cache/llama-macos}"
FINGERPRINT="$(/usr/bin/python3 - "$SOURCE_DIR" "$ROOT_DIR/scripts/build-llama-macos.sh" <<'PY'
import hashlib, pathlib, subprocess, sys
source = pathlib.Path(sys.argv[1])
if not (source / 'include/llama.h').is_file():
    raise SystemExit('Missing llama.cpp source: ' + str(source))
digest = hashlib.sha256(b'arm64;macos=14.0;static;metal;accelerate\n')
digest.update(pathlib.Path(sys.argv[2]).read_bytes())
digest.update(pathlib.Path(sys.argv[2]).with_name('llama-build-sources.cmake').read_bytes())
digest.update(subprocess.check_output(['xcrun', 'clang', '--version']))
digest.update(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']))
for directory in ('cmake', 'common', 'ggml', 'include', 'src', 'tools/mtmd', 'vendor'):
    for path in sorted((source / directory).rglob('*')):
        if path.is_file() and not any(part.startswith('.') for part in path.relative_to(source).parts):
            digest.update(path.relative_to(source).as_posix().encode())
            digest.update(path.read_bytes())
digest.update((source / 'CMakeLists.txt').read_bytes())
print(digest.hexdigest())
PY
)"
if [[ -f "$OUTPUT_DIR/lib/libllama.a" &&
      -f "$OUTPUT_DIR/include/module.modulemap" &&
      -f "$OUTPUT_DIR/build.sha256" &&
      "$(cat "$OUTPUT_DIR/build.sha256")" == "$FINGERPRINT" &&
      "$(xcrun lipo -archs "$OUTPUT_DIR/lib/libllama.a")" == arm64 ]]; then
  printf 'llama.cpp 執行核心已是最新版本（arm64）。\n'
  exit 0
fi
CMAKE_BIN="${CMAKE_BIN:-$(command -v cmake || true)}"
if [ -z "$CMAKE_BIN" ] && [ -x "$HOME/Library/Python/3.9/bin/cmake" ]; then
  CMAKE_BIN="$HOME/Library/Python/3.9/bin/cmake"
fi
if [ -z "$CMAKE_BIN" ]; then
  echo 'CMake is required. Install CMake or set CMAKE_BIN.' >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR/include" "$OUTPUT_DIR/lib"
"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_PROJECT_INCLUDE="$ROOT_DIR/scripts/llama-build-sources.cmake" \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_COMMON=ON \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DLLAMA_OPENSSL=OFF
"$CMAKE_BIN" --build "$BUILD_DIR" --config Release --target llama mtmd --parallel "${BUILD_JOBS:-8}"
xcrun libtool -static -o "$OUTPUT_DIR/lib/libllama.a.new" \
  "$BUILD_DIR/src/libllama.a" "$BUILD_DIR/tools/mtmd/libmtmd.a" \
  "$BUILD_DIR/ggml/src/libggml.a" "$BUILD_DIR/ggml/src/libggml-base.a" \
  "$BUILD_DIR/ggml/src/libggml-cpu.a" \
  "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" \
  "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"
if [[ "$(xcrun lipo -archs "$OUTPUT_DIR/lib/libllama.a.new")" != arm64 ]]; then
  printf 'llama.cpp 執行核心必須僅包含 arm64。\n' >&2
  exit 1
fi
mv "$OUTPUT_DIR/lib/libllama.a.new" "$OUTPUT_DIR/lib/libllama.a"
cp "$SOURCE_DIR/include/llama.h" "$SOURCE_DIR/ggml/include/"*.h \
   "$SOURCE_DIR/tools/mtmd/mtmd.h" "$SOURCE_DIR/tools/mtmd/mtmd-helper.h" "$OUTPUT_DIR/include/"
cat > "$OUTPUT_DIR/include/module.modulemap" <<'MODULE'
module llama {
    header "llama.h"
    header "mtmd.h"
    header "mtmd-helper.h"
    link "llama"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    export *
}
MODULE
printf '%s\n' "$FINGERPRINT" > "$OUTPUT_DIR/build.sha256"
printf 'Built Apple Silicon macOS llama library: %s\n' "$OUTPUT_DIR/lib/libllama.a"
