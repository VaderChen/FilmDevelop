# Vulkan 反算效能量測

本文件保存第一階段的 unmix 微核心量測。後續完整 GPU 串接、計算盤點及端到端量測見 [Vulkan 三模組移植](VULKAN_FILM.md)。

量測範圍為獨立 `unmix()`：CPU 單執行緒 double 與 GPU FP32，並將 GPU 結果帶回底片／顯影／掃描流程檢查最終成品。尚未整合 App，沒有全 GPU 或正式混合後端的端到端效能數據。

## 方法

- 使用既有 CPU 效能測試的 2048×1365、6000×4000 合成影像與 Portra 400 預設配方；輸入與配方 SHA-256 必須符合原始 manifest。
- 先執行原生 CPU CLI，單次量測完整流程耗時及程序峰值 RSS，提供同一輪測試的參照。此單次值不能替代原有三次中位數 CPU 基準。
- 在另一個程序擷取真實光譜反算輸入，保留 CPU 原始 double 輸入；CPU 使用建置副本暴露的原始 `unmix()`，沒有另外寫一套比較公式。每次量測後檢查輸出確實重現擷取時的 CPU 結果。
- CPU 與 GPU 各先執行一次，再循序量測三次，交替先後順序，取中位數。CPU 計時含讀取輸入、反算及寫入預先配置的輸出；GPU 主機時間包含每次緩衝區配置、映射、複製上傳、同步、dispatch、回讀複製及內部資源釋放。輸入擷取、double 轉 FP32 封裝、結果檢查及傳回陣列的最終釋放不計入這段 GPU 計時。本機兩種尺寸均為單次 dispatch，未碰到裝置上限，不能宣稱已驗證大圖分批。
- 額外保留 GPU timestamp 與提交等待時間；不可拿純 dispatch 時間冒充含傳輸時間。
- Runtime 初始化含 Vulkan instance、裝置及管線建立。首次 GPU 執行表示「本程序第一次」，沒有清除系統或驅動 shader cache，不宣稱為全機冷啟動。
- 開啟 Vulkan 一般與同步驗證，停用 MoltenVK fast math。每次 GPU 量測均驗證分量誤差 < 0.001；最終混合成品與同輪原生 CPU CLI 成品比較，所有像素最大 ΔE00 必須 < 2。
- 記憶體以 `wait4` 取得單一程序峰值 RSS。GPU 測試程序同時保留 CPU／GPU 資料與兩份成品，且執行多次計算，該峰值屬於測試工具；不能當成正式 GPU 後端的記憶體用量，也不是 GPU VRAM 峰值。

## 實測結果（2026-09-30）

Apple M4 Pro／macOS／MoltenVK，驗證層開啟。時間取三次中位數，兩種尺寸均使用相同 Portra 400 預設配方。

| 影像尺寸 | CPU unmix | GPU 含配置與傳輸 | GPU timestamp | 反算加速倍率 |
| --- | ---: | ---: | ---: | ---: |
| 2048×1365（約 280 萬） | 830.59 ms | 21.06 ms | 13.34 ms | 39.4 倍 |
| 6000×4000（2400 萬） | 7427.47 ms | 95.27 ms | 36.66 ms | 78.0 倍 |

GPU 主機耗時的三次範圍分別為 10.22–21.62 ms、89.57–98.01 ms；GPU 排程、時脈與驗證層會影響波動，不能只挑最快一次。這個倍率比較現有單執行緒 double CPU 與已通過成品驗證的 FP32 GPU；未與多執行緒／SIMD CPU 比較。

Runtime 初始化分別為 17.74、17.81 ms；本程序首次 GPU 完整呼叫分別為 20.13、99.05 ms，兩者分開記錄。未清除 shader cache，不能據此宣稱全機冷啟動成本。

| 影像尺寸 | 同輪 CPU 完整 CLI（單次） | 原生 CPU 峰值 RSS | GPU 比對工具峰值 RSS | 最終成品最大 ΔE00 |
| --- | ---: | ---: | ---: | ---: |
| 約 280 萬 | 3.64 s | 177.6 MiB | 552.4 MiB | 0.00573212 |
| 2400 萬 | 31.34 s | 1179.5 MiB | 4142.6 MiB | 0.00686957 |

Vulkan 錯誤、警告、CPU 回退均為 0；兩種尺寸的每次完整 GPU 呼叫都只需要一次 dispatch。反算分量最大誤差分別為 1.55e-6、1.67e-6。成品 ΔE 是相對同輪原生 C++ CPU CLI，這兩組大圖沒有另跑 Swift 參考；Swift 的十組 Smoke 結果見前述文件。

2400 萬像素的反算占同輪 CPU 整體約 24%。在其他成本不變的理想假設下，單獨替換這段最多可省約 7.3 秒，約 23%；**這是依分段量測推估，不是完整 GPU 後端實測**。顯影與其餘光譜運算仍需移植，才能進一步降低原先 3X 秒的總時間。

GPU 比對工具額外保留 double 輸入、CPU／GPU 中間結果與兩份最終成品，且做暖機、重複計算及逐像素比較；其 4.0 GiB 峰值不能解讀成正式 GPU 版比 CPU 多用這麼多記憶體。正式後端記憶體效率仍待整合後另測。

完整數據為 `build/photocore-vulkan-smoke/performance-ra2r77dp/report.json`（`completed: true`）；同目錄 `measured-bin` 保存對應 SHA-256 的實测執行檔、shader 與底片資料。結果整理後的程式亦重新建置，11 項 CTest 通過，包含效能模式的基本執行與結果檢查。

## 重跑

先依 [Vulkan Smoke](VULKAN_SMOKE.md) 完成建置與環境設定，並備妥 [CPU 效能測試](PERFORMANCE.md) 的 `performance/manifest.json`：

```sh
python3 experiments/PhotoCoreCpp/tools/benchmark_vulkan.py \
  --fixtures build/photocore-cpp/performance \
  --build build/photocore-vulkan-smoke \
  --environment build/photocore-vulkan-smoke/runtime/environment.json
```

每次使用新的 `build/photocore-vulkan-smoke/performance-*` 目錄，保存成品、程序記錄、GPU sidecar 與 `report.json`。只有 `completed: true` 才代表兩種尺寸均完成。量測期間應避免其他重負載程序。
