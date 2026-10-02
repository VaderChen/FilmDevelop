# 內建 CPU RAW 解析

混合版本以 Go 管理主程序、UI 與工作排程；macOS Swift 與 Windows C++ 都透過相同 PhotoRAW C 介面使用 LibRaw 0.22.2。兩個平台已有安裝封裝，Windows 版本尾碼為 Beta。預設保留系統原生解析，系統不支援時嘗試共用軟體解析。

設定 → 加速 → RAW 加速可選擇系統原生解析（預設）或內建軟體解析。切換目前 RAW 時以原始快照重新解碼，保留照片識別、配方、裁切、修復與編輯歷史；失敗則保留原方式與像素。匯入、重新啟動還原及批次輸出共用同一個選擇。JPEG、PNG 等一般圖片不受影響。

## 建置

Xcode 的 Build RAW 階段執行 `scripts/build-raw-macos.sh`，第一次下載並核對 SHA-256 固定版本 LibRaw 0.22.2，以 Xcode clang 建置 arm64 CPU 靜態庫。Windows x64 使用 `scripts/build-raw-windows.py` 交叉編譯。兩者透過 `scripts/build-raw-dependencies.py` 固定來源與 SHA-256，靜態連結 zlib 1.3.2、libjpeg-turbo 3.1.4.1；同時啟用上游 X3F。相依庫使用 CMake／Ninja 建置，不增加執行期外部 DLL 或下載需求。

相機 mapping 存在 `Mapping/*.cube.gz`，建置時驗證原始 SHA-256 並解壓到 App 的 RAWMapping。授權和上游來源隨 App 放入 RAWLicenses。LibRaw 依 CDDL-1.0 提供；未修改上游來源、未啟用額外 demosaic packs。

## 資料與限制

- 線性 RGB 與套用 mapping 的 sRGB「原片」分開輸出；CPU demosaic 一次，重新打包兩種輸出。不透過 PNG 或 RGB8 重建編輯輸入。
- 線性資料維持 RGBA Float32，但上游仍是已截斷的 RGB16，範圍 0…1，不能保留 Apple 原生的負值及超過 1 的高光。未升級為完整場景線性 HDR 解碼器。
- 編輯縮圖直接採半尺寸、不再縮到 2048；互動用的 1024 預覽也從同一半尺寸來源製作。開啟「使用原檔編輯」與匯出使用完整解析度。
- macOS 軟體路徑目前仍於載入時準備完整解析度及半尺寸，Windows 編輯路徑使用完整解碼後縮放，因此首次載入仍會等待完整 demosaic；本選項不保證所有相機都更快。X-Trans 完整解析尤其慢，尚未採用會改變局部像素的 snapshot 平行候選。
- LibRaw 使用單一 CPU demosaic 執行緒。全域 mutex 包覆每個 LibRaw 物件完整生命週期，以避免 LIBRAW_NOTHREADS 的共用狀態衝突。最終打包及 LUT 使用最多 4 個 CPU 執行緒。
- 內嵌相機 JPEG 可用於列表與載入提示，不能當成 RAW 編輯來源。macOS 系統解碼失敗或只產生與內嵌預覽矛盾的近黑像素時，改嘗試 LibRaw；Windows 不接受一般 TIFF／JPEG／PNG 解碼器或缺少 IWICDevelopRaw 顯影介面的 codec 冒充 RAW。兩者皆失敗時回報解碼錯誤。
- mapping 只用於「原片」顯示；查詢依相機 make/model，未知機型使用 LibRaw 固定顯影。11 機型、每機型 3 張的校色結果見 `Mapping/validation.json`。ΔE76 平坦中間調遮罩中位數 < 2 不代表全圖、所有場景或半尺寸細節一致。Pentax K-3 高 ISO 已知例外仍保留。

## 驗證

公開樣本清單位於 `engine/verification/raw/corpus.json`，含來源、CC0 授權、壓縮註記及 SHA-256；原始檔僅下載到 build，不能把私有 RAW 提交到儲存庫或上傳公開服務。

- `download.py`：依固定清單下載、核對雜湊，單檔最多 300 MiB，最多 3 個並行下載。
- `probe.cpp`、`run.py`、`run-windows.ps1`：透過正式 C 介面執行完整解碼及半尺寸解碼，記錄 EXIF、尺寸、有限數值、完整像素指紋與固定網格取樣；每張分開行程與逾時限制。
- `compare.py`：比對兩平台結果，失敗格式不列為通過。完整指紋相同才表示全圖相同；指紋不同時只對取樣報數值容差。
- `run-engine.py`、`run-engine-windows.ps1`：透過正式 JSONL 協定驗證系統／軟體路由、縮放、PNG16 輸出、錯誤處理與原檔不變。

本輪實測矩陣及尚缺解碼方案見 `engine/verification/raw/README.md`。相機映射的舊驗證仍以 `Mapping/validation.json` 為準，不能把本輪解碼成功視為所有機型的色彩校正驗收。
