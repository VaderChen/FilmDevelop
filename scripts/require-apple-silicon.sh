#!/bin/bash
# Source before building or verifying project-owned native components.
if [[ "$(/usr/bin/uname -s)" != Darwin || "$(/usr/bin/uname -m)" != arm64 ]]; then
  printf 'PhotoStyleApp 僅支援 Apple Silicon Mac（macOS 14 以上）。請在 Apple Silicon 上以原生終端機執行。\n' >&2
  exit 1
fi
