#!/bin/bash
# 舊入口保留相容；預設產生 Windows x64 免安裝 ZIP。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/package-windows.py" "$@"
