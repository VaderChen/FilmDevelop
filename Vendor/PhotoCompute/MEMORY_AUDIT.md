# 影像後端記憶體檢查（2026-09-30）

環境：Apple M4 Pro、macOS 27.0；檢查 macOS 原生、App Vulkan 中介層與 RAW 輸入。Windows 未執行。此次確認並修正 Vulkan 失敗路徑的 command buffer 累積，也補上切回原生及關閉 App 時的 engine 快取釋放。

## 確認的問題與修正

`Context::dispatch` 原本只在正常結束時呼叫 `vkFreeCommandBuffers`。錄製開始／結束、timestamp 讀取等步驟拋出例外時，command buffer 留在長駐的 command pool；下次 `vkResetCommandPool` 不會解除這些 handle 的配置。裝置最後銷毀才會回收，長時間執行並反覆失敗會持續累積。

改為 scope RAII，正常與例外路徑都釋放；等待 GPU 失敗仍先執行既有的 device idle 處理，才進行解構。故障注入直接包裝真實 Vulkan runtime 的 API，不複製運算邏輯。

| 驗證 | 修正前 | 修正後 |
| --- | --- | --- |
| 每個 context 注入 60 次失敗後，仍配置的 command buffer 最大數 | 60 | 0 |
| context 銷毀後仍配置的 GPU bytes／device | 0／0 | 0／0 |
| Vulkan validation error／warning | 0／0 | 0／0 |

測試共 3 個 context、180 次注入失敗、300 次後續成功 dispatch，以及 10 次建立 device 後的初始化失敗。原始報告：`build/memory-audit/vulkan-before.json`、`build/memory-audit/vulkan-after.json`。回歸測試保存在 `experiments/PhotoCoreCpp/verification/vulkan_lifetime.cpp`，納入 CTest。

另一項是可達的長駐快取，並非失去擁有者的 leak：原本 Swift 靜態 engine 在切回原生後仍持有 Vulkan 裝置、pipeline 與光譜 LUT。現在快取可釋放，成功初始化才快取；進行中的 provider 保留強參照，避免運算途中銷毀 engine。切回原生後，還會在舊預覽佇列完成時再次確認後端並清理，涵蓋尚未開始的懸停預覽。關閉 App 則先排空工作，再移除快取。

## App 與 RAW 的生命週期 Smoke

測試在來源副本加入配置／解構計數，不把追蹤程式放進產品熱路徑。使用實際 App adapter、C ABI、bundled MoltenVK 及共用完整影像處理入口。

- 5 次雙後端暖機、80 次 Vulkan 渲染、30 次 Vulkan → 原生切換。
- 清除快取後，仍存活的 provider 可以繼續運算；最後一位使用者完成後才釋放 engine。
- 無效光譜請求、損毀 RAW 的錯誤路徑。
- NEF 兩個解析選項各 4 次。此 NEF 在 LibRaw 會失敗並走原生回退，**不把回退當成 LibRaw 成功**。
- 額外產生未壓縮 Bayer DNG，10 次完整＋半尺寸 LibRaw 解碼，直接要求軟體解析成功，不允許回退。

結果：31 次 engine 建立、116 次 Vulkan provider 建立，全部配對釋放。影像管線累計追蹤 471,859,200 bytes、軟體 RAW 累計 15,564,800 bytes，最後存活計數皆為 0。RAW 包裝器的 `Data(bytesNoCopy:)`／CGDataProvider 擁有權轉移，以及管線 CGDataProvider 的 retain／release 未發現未配對。

完整結果：`build/compute-memory-AD8wER/swift-memory.json`。另一次關閉 malloc stack logging 的相同測試，80 次渲染後 footprint 約 647.5 MiB，最後經背景回收後約 387.9 MiB；全尺寸 RAW 階段暫時約 1.7 GiB。這是測試程序的整體 footprint，包含 Core Image／Metal／配置器保留空間，不等於存活的 App 影像 bytes，也不是 App 正常操作的峰值保證。報告：`build/memory-audit/no-stack-logging/swift-memory.json`。

## leaks 仍有一項觀察

未加排除規則的 macOS `leaks --atExit` 回報 **4 個配置、合計 384 bytes**：兩個 Core Image `CI::PooledDispatchQueue`（各 160 bytes）及其 specific 配置（各 32 bytes）。堆疊在 Core Image 的 `ObjectCache::clear`／`performDeferredRoot` 背景回收。

另以相同 App 影像管線連續 80 次純原生運算，完全不建立 Vulkan engine 或呼叫 LibRaw，仍重現相同的 384 bytes。純 Core Image 簡單模糊＋RAW 的較小對照程式則為 0；因此只能確認此觀察與原生影像管線的 Core Image 回收有關，不能斷言所有 Core Image 使用方式都會出現，也尚未判定是系統內部洩漏或掃描工具判定問題。

原始報告保留在 `build/compute-memory-AD8wER/leaks.log` 與原生對照 `build/compute-memory-IOVS6V/leaks.log`。**不宣稱整個程序零 leak**，測試腳本保留 `leaks` 的非零退出碼；Swift 的 `passed` 僅表示追蹤的生命週期斷言通過。

## 驗證與重跑

Xcode Debug 最終建置成功、13 項 CTest 全部通過。資源釋放修改後重跑 4 組 App 完整處理成品 Smoke，最大 ΔE00 為 1.20384976288，仍小於 2；本輪沒有更改演算法。色差報告：`build/compute-edge-nV7Wzz/report.json`。

```sh
ctest --test-dir build/photocore-vulkan-full --output-on-failure
bash scripts/verify-macos-compute-memory.sh
COMPUTE_MEMORY_NATIVE_ONLY=1 bash scripts/verify-macos-compute-memory.sh
bash scripts/verify-macos-compute-edge.sh
```

Swift Smoke 及腳本依儲存庫既有規則屬於本機測試，不納入 Git。測試使用 384 px 影像處理與全尺寸 NEF；DNG 是配置／釋放測試資料，不是色彩正確性基準。未涵蓋整晚操作、所有機種、所有 UI 快取、AI 模型或 Windows 驅動，故不能用本輪結果保證所有路徑永遠沒有洩漏。
