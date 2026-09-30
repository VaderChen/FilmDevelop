# 內建 CPU RAW 解析

正式使用請選「系統原生解析」。內建軟體解析 (測試中) 是為 Windows 平台做準備，目前供測試使用；尚未提供 Windows 安裝版。

設定 → 加速 → RAW 加速可選擇系統原生解析（預設）或內建軟體解析。切換目前 RAW 時以原始快照重新解碼，保留照片識別、配方、裁切、修復與編輯歷史；失敗則保留原方式與像素。匯入、重新啟動還原及批次輸出共用同一個選擇。JPEG、PNG 等一般圖片不受影響。

## 建置

Xcode 的 Build RAW 階段執行 `scripts/build-raw-macos.sh`，第一次下載並核對 SHA-256 固定版本 LibRaw 0.22.2，以 Xcode clang 建置 arm64 CPU 靜態庫。無 Homebrew、實驗目錄、外部執行檔或執行期下載依賴；zlib 使用 macOS SDK。Windows 封裝與測試不在本次範圍。

相機 mapping 存在 `Mapping/*.cube.gz`，建置時驗證原始 SHA-256 並解壓到 App 的 RAWMapping。授權和上游來源隨 App 放入 RAWLicenses。LibRaw 依 CDDL-1.0 提供；未修改上游來源、未啟用額外 demosaic packs。

## 資料與限制

- 線性 RGB 與套用 mapping 的 sRGB「原片」分開輸出；CPU demosaic 一次，重新打包兩種輸出。不透過 PNG 或 RGB8 重建編輯輸入。
- 線性資料維持 RGBA Float32，但上游仍是已截斷的 RGB16，範圍 0…1，不能保留 Apple 原生的負值及超過 1 的高光。未升級為完整場景線性 HDR 解碼器。
- 編輯縮圖直接採半尺寸、不再縮到 2048；互動用的 1024 預覽也從同一半尺寸來源製作。開啟「使用原檔編輯」與匯出使用完整解析度。
- 目前仍於載入時準備完整解析度及半尺寸，因此首次載入仍會等待完整 demosaic；本選項不保證所有相機都更快。X-Trans 完整解析尤其慢，尚未採用會改變局部像素的 snapshot 平行候選。
- LibRaw 使用單一 CPU demosaic 執行緒。全域 mutex 包覆每個 LibRaw 物件完整生命週期，以避免 LIBRAW_NOTHREADS 的共用狀態衝突。最終打包及 LUT 使用最多 4 個 CPU 執行緒。
- 內嵌相機 JPEG 的快速預覽與目錄縮圖仍使用原有容器抽取／ImageIO；它們不是感光元件 RAW 解碼，不會進入編輯來源。
- mapping 只用於「原片」顯示；查詢依相機 make/model，未知機型使用 LibRaw 固定顯影。11 機型、每機型 3 張的校色結果見 `Mapping/validation.json`。ΔE76 平坦中間調遮罩中位數 < 2 不代表全圖、所有場景或半尺寸細節一致。Pentax K-3 高 ISO 已知例外仍保留。

## 驗證

本機 `scripts/verify-macos-raw-acceleration.sh` 使用隔離偏好設定，測試真實 WebKit 選單、原生 bridge、設定保存、目前 RAW 重新解析、編輯歷史保留、半尺寸處理、全尺寸匯出、失敗回復及一般圖片路徑。校色回歸另外將 36 張 RAW（含 3 張已知高 ISO 例外）的全尺寸與半尺寸輸出比對凍結版本；72 組 mapped RGB8 全部逐 byte 相同。這不宣告既有例外已修正。
