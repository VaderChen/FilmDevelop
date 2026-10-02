#!/bin/bash
# 由建置腳本 source；依 SwiftPM 回報的產品目錄解析模組及連結輸入，
# 同時支援新版 Swift Build 與舊工具鏈的產物配置。
resolve_swift_package_product() {
  local products="$1" module="$2" object
  SWIFT_PRODUCT_LINK_INPUTS=()
  if [[ -e "$products/$module.swiftmodule" ]]; then
    SWIFT_PRODUCT_MODULES="$products"
  elif [[ -e "$products/Modules/$module.swiftmodule" ]]; then
    SWIFT_PRODUCT_MODULES="$products/Modules"
  else
    printf '找不到 Swift 模組：%s（%s）\n' "$module" "$products" >&2
    return 1
  fi
  if [[ -f "$products/$module.o" ]]; then
    SWIFT_PRODUCT_LINK_INPUTS=("$products/$module.o")
  elif [[ -f "$products/lib$module.a" ]]; then
    SWIFT_PRODUCT_LINK_INPUTS=("$products/lib$module.a")
  else
    for object in "$products/$module.build/"*.o; do
      [[ -f "$object" ]] && SWIFT_PRODUCT_LINK_INPUTS+=("$object")
    done
  fi
  if [[ ${#SWIFT_PRODUCT_LINK_INPUTS[@]} -eq 0 ]]; then
    printf '找不到 Swift 連結產物：%s（%s）\n' "$module" "$products" >&2
    return 1
  fi
}

# Python 匯出工具沿用相同解析規則；NUL 分隔可保留路徑中的空白及換行。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  resolve_swift_package_product "$@"
  printf '%s\0' "$SWIFT_PRODUCT_MODULES" "${SWIFT_PRODUCT_LINK_INPUTS[@]}"
fi
