# Windows x64 安裝檔

此流程沿用 YourDesk 的 NSIS、每位使用者安裝與保留資料的解除安裝設計。建置不依賴 YourDesk 專案。

產品名稱固定為 **FilmDevelop**。Windows 的版本顯示文字統一在組建編號後加上 **Beta**，涵蓋設定頁、主程式與安裝程式版本資源；檔名、產品名稱、數字版本與更新比對維持原值。macOS 不加此標記。此腳本只產生並驗證本機檔案；GitHub Release 另行發布。

## 建置

從專案根目錄執行：

```sh
bash scripts/build-windows-installer.sh
```

需要既有交叉編譯工具 Go、Python 3.9 以上、CMake、Ninja、MinGW-w64 x64（含 windres／dlltool）、Vulkan headers、glslangValidator，另需 NSIS `makensis` 與 7-Zip `7zz`／`7z`。macOS 預設以 Homebrew 定位 Vulkan headers；也可使用 `VULKAN_HEADERS_DIR` 指定 include 目錄。腳本不安裝工具。

預設先重建 Windows Go GUI／CLI 與 C++ 元件，再封裝、解壓驗證。只重做封裝可使用：

```sh
bash scripts/build-windows-installer.sh --no-build
```

`--no-build` 使用現有產物並檢查版本、資源、架構與相依，**不保證現有產物反映最新程式碼**。原始碼變更後使用預設完整建置。可使用 `--build-dir` 與 `--output-dir` 更改路徑；`WINDOWS_CROSS_BUILD_DIR` 也可指定交叉編譯目錄。

版本取自 `PhotoStyleApp.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION` 與 `CURRENT_PROJECT_VERSION`，不另建 Windows 版本來源。目前顯示為 `1.26.1002 build 1208 Beta`，Windows 數字版本為 `1.26.1002.1208`。圖示直接封裝專案既有各尺寸 PNG，保留原有像素與透明度。

預設輸出至 `dist/windows-x64/`：

- `FilmDevelop-<版本>-build<組建>-windows-x64-setup.exe`
- `SHA256SUMS`：安裝檔 SHA-256。
- `verification.json`：檔案清單、架構、靜態 DLL 相依、GUI 資源與解壓雜湊驗證結果。
- `nsis-build.log`、`archive-check.log`、`payload.nsh`：本次封裝的診斷與安裝／移除清單。

建置期間使用暫存資料夾，NSIS 警告視為錯誤；檢查通過才替換輸出的安裝檔。Go 主程式的 `.syso` 資源只在編譯期間存在，不覆蓋另一個建置留下的資源。

## 安裝與檔案配置

- 限 Windows 10／11 原生 x64（AMD64）；拒絕 x86 與 ARM64。
- 安裝路徑：`%LOCALAPPDATA%\Programs\FilmDevelop`，可改至空資料夾或本產品已擁有的資料夾。
- 主程式登錄於 HKCU 的 64 位元檢視，不要求系統管理員、不安裝服務、不加入開機自動執行。缺少 VC++ x64 Runtime 時，Microsoft 官方前置元件安裝可能要求提權；靜默／離線安裝應先部署 Runtime。
- `FilmDevelop.exe` 是 Go／Wails GUI；`filmdevelop-cli.exe` 為 CLI，避免 Windows 不分大小寫的同名衝突。
- `engine/filmdevelop-engine.exe` 是 Go 共用 JSONL 契約的 C++／WIC 工作程序；同目錄另有 `RAWMapping` 色彩資料、`libPhotoCompute.dll`、階段 CLI、shader、底片資料與從 Go 目錄產生的中性配方。
- WIC 解碼 JPEG／PNG／TIFF，套用 EXIF 方向與來源 ICC；RAW 會實際建立系統解析器確認可用性；檔案無法解碼時使用共用 PhotoRAW／LibRaw 0.22.2 備援，亦可明確選用 LibRaw。系統選項優先使用實際計算探測通過的 Vulkan，否則使用 CPU；選項與持久化設定會在啟動時重新核對。
- Windows 已接入 37 個既有配方及 1 個隱藏相容配方，包含乳劑顆粒、光暈、光譜底片、顯影、掃描、數位／相機色彩、HDR、裁切、外框、日期、GGUF AI 與 ONNX LaMa 修復。輸出支援 JPEG、WebP、PNG／TIFF 8／16 bit，以及 sRGB／Adobe RGB／Display P3。預設回填拍攝 EXIF，可在設定中關閉。
- 主程式需要 WebView2 Evergreen Runtime；缺少或版本過舊時使用 Wails 既有 Microsoft 下載流程，提示使用者安裝。離線環境請預先部署官方 x64 Runtime，詳見 [Microsoft 部署說明](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)。
- Vulkan DLL 需要顯示卡驅動提供 `vulkan-1.dll`，相依檢查會明確列為 GPU 驅動；不將它視為 Windows 內建 DLL，也不私自附帶驅動。
- 配方與 WebView2 快取放在 `%APPDATA%\FilmDevelop`；`FILMDEVELOP_DATA_DIR` 可覆寫。解除安裝保留此處、照片及匯出檔。

NSIS 啟動器本身為 x86 Unicode，可在 x64 Windows 執行；內含的主程式、CLI 與計算 DLL 全部為 x64。安裝流程會檢查原生架構，不能以啟動器 PE 的架構判斷產品架構。

更新前逐一確認套件檔案未被占用；互動安裝可重試，靜默安裝回傳非零錯誤，不強制結束程式。安裝、占用檢查及解除安裝由同一份檔案清單產生；只刪除本套件列出的檔案及空目錄，保留安裝目錄中其他檔案。搬動安裝位置後，舊位置的解除安裝保留新位置的登錄與捷徑。

靜默命令（`/D=` 必須放最後，路徑不另外加引號）：

```text
FilmDevelop-<版本>-build<組建>-windows-x64-setup.exe /S /D=C:\Users\使用者\AppData\Local\Programs\FilmDevelop
"C:\Users\使用者\AppData\Local\Programs\FilmDevelop\Uninstall.exe" /S
```

退出碼：`0` 成功、`2` 檔案占用／另一個安裝程序、`3` 目錄或檔案寫入失敗、`4` 不支援的 Windows／CPU 架構；一般使用者取消由 NSIS 回傳取消狀態。

## Smoke 與驗證界線

```sh
python3 engine/verification/windows-installer-smoke.py
python3 engine/verification/inspect-windows.py build/windows-cross
go -C desktop vet ./...
go -C desktop test ./internal/...
```

本機檢查涵蓋 PE32+／AMD64、GUI 子系統、圖示、Manifest、版本、一般與延遲 DLL 相依、NSIS 壓縮完整性、解壓後逐檔 SHA-256。負向 Smoke 注入錯誤架構、缺少 DLL、錯誤版本與截斷資料，確認封裝會拒絕。

已透過 YourDesk MCP 在 Windows 10 22H2 x64、WebView2、GTX 1060 上驗證 CPU／Vulkan、照片編輯／匯出、GGUF → Go 配方 → ONNX LaMa → PNG16。兩平台各 304 組 CPU／GPU 的 Swift 參考比較通過，共 1,216 組。另已在隔離目錄補齊 Vulkan validation layer，通過光學檢查與 180 次 GPU 故障注入，沒有 validation warning／error。資料移轉也已用本機舊 Swift 資料與 Windows 隔離資料驗證，不修改使用者原圖。

上述為不同階段的實機紀錄，不代表新安裝檔已重新在所有環境執行。封裝器的 `windowsExecutionVerified`、`windowsInstallUninstallVerified`、`windowsGPUVerified` 描述該次封裝，不能直接承襲先前版本結果；原生功能是否已提供由 `fullWindowsRendererAvailable` 表示。驗證細節見[功能恢復紀錄](../../desktop/RESTORATION.md)。

仍待擴大驗證 Windows 11、乾淨電腦缺少 WebView2／VC++ Runtime、離線安裝及其他 GPU 驅動。Nikon HE／HE*、GoPro GPR 的直接 RAW 解碼仍缺失；原生 RAW、主體、景深、降噪與日期字形可能與 Apple 框架不同。安裝檔未簽 Authenticode，Windows 持續標示 Beta。

## 配方跨平台驗證

Windows 與測試主機共用 `engine/cpp/render_pipeline.hpp`，保留 Swift 的階段順序、低強度原片混合、黑白及掃描順序。Vulkan 將底片、乳劑、數位風格與 HDR 放在同一計算圖；CPU 使用同一套資料作為失敗回退。LibRaw 的線性底片來源與相機原片分開保存。

數位／相機風格的色彩表由 `scripts/export-windows-style-data.py` 從現有 Swift 程式產生；65³ 線性 Float32 表採 sRGB 取樣座標。光暈、銳化、分區遮罩與 HDR 保留獨立空間處理，不烘焙進色彩表。表格插值與平台浮點差異不保證逐位元相同。更新 Swift 風格時需重跑匯出腳本；交叉編譯會檢查來源與資料雜湊，拒絕使用過期表格。

測試入口：`photo_compute_optics_verify` 比對 CPU／Vulkan、透明度與單次傳輸；`photo_compute_styles_verify` 使用真正 Swift 引擎產生的同圖金樣本，比對完整配方管線。Windows 實機另外執行全部配方、CPU 備援與 Go／WebView2 切換配方 Smoke。
