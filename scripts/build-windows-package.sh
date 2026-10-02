#!/bin/bash
# 從 macOS 建置 Windows x64 免安裝 ZIP；不執行發布。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/package-windows.py" "$@"
