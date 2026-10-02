#!/bin/bash
# 在 macOS 交叉編譯 Windows x64；建置成功不代表 Windows 實機驗收。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${WINDOWS_CROSS_BUILD_DIR:-$ROOT/build/windows-cross}"
for TOOL in go cmake ninja python3 x86_64-w64-mingw32-g++ x86_64-w64-mingw32-windres x86_64-w64-mingw32-dlltool glslangValidator; do
  command -v "$TOOL" >/dev/null || { printf '缺少交叉編譯工具：%s\n' "$TOOL" >&2; exit 1; }
done
VULKAN_HEADERS="${VULKAN_HEADERS_DIR:-$(brew --prefix vulkan-headers)/include}"
[[ -f "$VULKAN_HEADERS/vulkan/vulkan.h" ]] || { echo '缺少 Vulkan 標頭' >&2; exit 1; }
mkdir -p "$BUILD/bin" "$BUILD/imports"
python3 "$ROOT/engine/contract/generate.py" --check
python3 "$ROOT/scripts/export-windows-style-data.py" --check
python3 "$ROOT/scripts/export-windows-editor-data.py" --check
python3 "$ROOT/scripts/export-color-profiles.py" --check
python3 "$ROOT/scripts/prepare-desktop.py"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go -C "$ROOT/desktop" build -trimpath -ldflags '-s -w' -o "$BUILD/bin/filmdevelop.exe" ./cmd/filmdevelop
python3 "$ROOT/scripts/windows_resources.py" --output "$BUILD/bin/FilmDevelopGo.exe" --resources "$BUILD/resources"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go -C "$ROOT/desktop" test -trimpath -c -o "$BUILD/bin/engine-tests.exe" ./internal/engine
cmake -S "$ROOT/engine/cpp" -B "$BUILD/contract" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/experiments/PhotoCoreCpp/cmake/windows-x64-mingw.cmake" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD/contract" -j4
# 只建立 Loader 匯入庫，不複製本機 macOS 程式庫，也不假裝提供 GPU 驅動。
# 函式清單取自實際呼叫，若新增 Vulkan 入口即可一併重建。
python3 - "$ROOT" "$BUILD/imports/vulkan-1.def" <<'PY'
import re,sys
from pathlib import Path
root=Path(sys.argv[1]);symbols=set()
for source in (root/'experiments/PhotoCoreCpp/vulkan').glob('*.cpp'):
    symbols.update(re.findall(r'\b(vk[A-Z]\w+)\s*\(',source.read_text()))
Path(sys.argv[2]).write_text('LIBRARY vulkan-1.dll\nEXPORTS\n'+'\n'.join(sorted(symbols))+'\n')
PY
x86_64-w64-mingw32-dlltool -d "$BUILD/imports/vulkan-1.def" -l "$BUILD/imports/libvulkan-1.a"
cmake -S "$ROOT/experiments/PhotoCoreCpp" -B "$BUILD/core" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/experiments/PhotoCoreCpp/cmake/windows-x64-mingw.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DPHOTOCORE_VULKAN_APP=ON -DVulkan_INCLUDE_DIR="$VULKAN_HEADERS" -DVulkan_LIBRARY="$BUILD/imports/libvulkan-1.a" \
  -DCMAKE_SHARED_LINKER_FLAGS='-static -static-libgcc -static-libstdc++'
cmake --build "$BUILD/core" -j4
python3 "$ROOT/scripts/build-raw-windows.py" "$BUILD/raw"
python3 "$ROOT/scripts/build-webp-windows.py" "$BUILD/webp"
python3 "$ROOT/scripts/prepare-neural-windows.py" "$BUILD/neural"
python3 "$ROOT/scripts/prepare-vision-windows.py" "$BUILD/vision"
bash "$ROOT/scripts/build-llama-windows.sh" "$BUILD/llama"
cmake -S "$ROOT/engine/windows" -B "$BUILD/native" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/experiments/PhotoCoreCpp/cmake/windows-x64-mingw.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DPHOTO_LLAMA_DIR="$BUILD/llama" -DPHOTO_NEURAL_DIR="$BUILD/neural" -DPHOTO_RAW_LIBRARY="$BUILD/raw/libphotoraw.a" -DPHOTO_WEBP_LIBRARY="$BUILD/webp/libphotowebp.a"
cmake --build "$BUILD/native" -j4
python3 - "$ROOT" "$BUILD/native/neutral-recipe.json" <<'PY'
import json,sys
from pathlib import Path
catalog=json.loads((Path(sys.argv[1])/'desktop/internal/recipes/catalog.json').read_text())
(Path(sys.argv[2]).parent/'style-catalog.json').write_text(json.dumps(catalog,ensure_ascii=False)+'\n')
neutral=next(style['adjustment'] for style in catalog['styles'] if style['id']=='original')
Path(sys.argv[2]).write_text(json.dumps(neutral,ensure_ascii=False)+'\n')
PY
python3 "$ROOT/engine/verification/inspect-windows.py" "$BUILD"
python3 "$ROOT/scripts/collect-desktop-licenses.py" "$BUILD/Licenses/Go"
cp "$ROOT/LICENSE.md" "$ROOT/THIRD_PARTY_NOTICES.md" "$BUILD/Licenses/"
cp "$ROOT/experiments/PhotoCoreCpp/third_party/nlohmann/LICENSE" "$BUILD/Licenses/nlohmann-json.txt"
printf 'Windows x64 交叉編譯完成；Windows 執行與 GPU 驗證尚未執行：%s\n' "$BUILD"
