#!/bin/bash
# Windows x64 本機視覺推論：共用 llama.cpp 核心，Vulkan 提供者以 DLL 動態載入。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build/windows-cross/llama}"
SOURCE="$ROOT/aiTest2/ThirdParty/llama.cpp"
HEADERS="${VULKAN_HEADERS_DIR:-$(brew --prefix vulkan-headers)/include}"
SPIRV_HEADERS="${SPIRV_HEADERS_DIR:-$(brew --prefix spirv-headers)/include}"
command -v glslc >/dev/null
mkdir -p "$BUILD/imports"
python3 - "$HEADERS/vulkan/vulkan_core.h" "$BUILD/imports/vulkan.def" <<'PY'
import re,sys
from pathlib import Path
symbols=set(re.findall(r'VKAPI_CALL\s+(vk\w+)\s*\(',Path(sys.argv[1]).read_text()))
Path(sys.argv[2]).write_text('LIBRARY vulkan-1.dll\nEXPORTS\n'+'\n'.join(sorted(symbols))+'\n')
PY
x86_64-w64-mingw32-dlltool -d "$BUILD/imports/vulkan.def" -l "$BUILD/imports/libvulkan-1.a"
cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
 -DCMAKE_TOOLCHAIN_FILE="$ROOT/experiments/PhotoCoreCpp/cmake/windows-x64-mingw.cmake" \
 -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc -DCMAKE_BUILD_TYPE=Release \
 "-DCMAKE_C_FLAGS=-ffile-prefix-map=$ROOT=." \
 -DCMAKE_CXX_FLAGS="-isystem $SPIRV_HEADERS -ffile-prefix-map=$ROOT=." \
 -DCMAKE_PROJECT_INCLUDE="$ROOT/scripts/llama-build-sources.cmake" \
 -DCMAKE_SHARED_LINKER_FLAGS='-static -static-libgcc -static-libstdc++ -Wl,--exclude-libs,ALL' \
 -DCMAKE_MODULE_LINKER_FLAGS='-static -static-libgcc -static-libstdc++ -Wl,--exclude-libs,ALL' \
 -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_VULKAN=ON \
 -DGGML_NATIVE=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_AVX512=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF \
 -DGGML_OPENMP=OFF -DGGML_BLAS=OFF -DGGML_METAL=OFF \
 -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
 -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_COMMON=ON -DLLAMA_OPENSSL=OFF -DLLAMA_CURL=OFF \
 -DVulkan_INCLUDE_DIR="$HEADERS" -DVulkan_LIBRARY="$BUILD/imports/libvulkan-1.a" -DVulkan_GLSLC_EXECUTABLE="$(command -v glslc)"
cmake --build "$BUILD" --target llama mtmd ggml-vulkan ggml-cpu -j4
mkdir -p "$BUILD/Licenses"
cp "$SOURCE/LICENSE" "$BUILD/Licenses/llama.cpp.txt"
cp "$SOURCE/licenses/LICENSE-jsonhpp" "$BUILD/Licenses/nlohmann-json.txt"
python3 - "$SOURCE/vendor/stb/stb_image.h" "$BUILD/Licenses/stb-image.txt" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
start=source.index('ALTERNATIVE A - MIT License')
end=source.index('ALTERNATIVE B',start)
Path(sys.argv[2]).write_text(source[start:end].rstrip('= \n')+'\n')
PY
printf 'Windows GGUF 原生核心建置完成：%s\n' "$BUILD"
