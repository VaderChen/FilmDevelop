#!/bin/bash
# 從 macOS 交叉編譯並產生 Windows x64 安裝檔；不執行遠端發布。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/package-windows.py" "$@"
