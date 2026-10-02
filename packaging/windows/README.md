# Windows x64 安裝檔

此流程參考 `/Users/vader/Codes/App/YourDesk/scripts/windows-installer.nsi`、`release.py` 與 `windows_runtime.py`，採用 NSIS、每位使用者安裝、桌面／開始功能表捷徑與保留使用者資料的解除安裝。建置時不需要 YourDesk，也不修改它的檔案。

產品名稱固定為 **FilmDevelop**。Windows 的版本顯示文字統一在組建編號後加上 **Beta**，涵蓋設定頁、主程式與安裝程式版本資源；檔名、產品名稱、數字版本與更新比對維持原值。macOS 不加此標記。測試完成後才另行發布 Release，這個腳本只在本機產生檔案。

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

版本取自 `PhotoStyleApp.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION` 與 `CURRENT_PROJECT_VERSION`，不另建 Windows 版本來源。目前顯示為 `1.26.0924 build 1107 Beta`，Windows 數字版本為 `1.26.924.1107`。圖示直接封裝專案既有各尺寸 PNG，保留原有像素與透明度。

預設輸出至 `dist/windows-x64/`：

- `FilmDevelop-<版本>-build<組建>-windows-x64-setup.exe`
- `SHA256SUMS`：安裝檔 SHA-256。
- `verification.json`：檔案清單、架構、靜態 DLL 相依、GUI 資源與解壓雜湊驗證結果。
- `nsis-build.log`、`archive-check.log`、`payload.nsh`：本次封裝的診斷與安裝／移除清單。

建置期間使用暫存資料夾，NSIS 警告視為錯誤；檢查通過才替換輸出的安裝檔。Go 主程式的 `.syso` 資源只在編譯期間存在，不覆蓋另一個建置留下的資源。

## 安裝與檔案配置

- 限 Windows 10／11 原生 x64（AMD64）；拒絕 x86 與 ARM64。
- 安裝路徑：`%LOCALAPPDATA%\Programs\FilmDevelop`，可改至空資料夾或本產品已擁有的資料夾。
- 登錄於 HKCU 的 64 位元檢視，不要求系統管理員、不安裝服務、不加入開機自動執行。
- `FilmDevelop.exe` 是 Go／Wails GUI；`filmdevelop-cli.exe` 為 CLI，避免 Windows 不分大小寫的同名衝突。
- `engine/filmdevelop-engine.exe` 是 Go 共用 JSONL 契約的 C++／WIC 工作程序；同目錄另有 `RAWMapping` 色彩資料、`libPhotoCompute.dll`、階段 CLI、shader、底片資料與從 Go 目錄產生的中性配方。
- WIC 解碼 JPEG／PNG／TIFF，套用 EXIF 方向與來源 ICC；RAW 會實際建立系統解析器確認可用性；檔案無法解碼時使用共用 PhotoRAW／LibRaw 0.22.2 備援，亦可明確選用 LibRaw。系統選項優先使用實際計算探測通過的 Vulkan，否則使用 CPU；選項與持久化設定會在啟動時重新核對。
- Windows 已接入全部 37 個內建配方的預覽與 sRGB JPEG／PNG／TIFF 輸出，包含乳劑顆粒、光暈、光譜底片、顯影藥水、掃描、數位／相機色彩及 HDR。AI、修復、裁切與裝飾尚未完成；有效的未支援參數會回報錯誤，不會省略後當作成功。
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

## 本機 Smoke 與 Release 前待驗證

```sh
python3 engine/verification/windows-installer-smoke.py
python3 engine/verification/inspect-windows.py build/windows-cross
go -C desktop vet ./...
go -C desktop test ./internal/...
```

本機檢查包括 PE32+／AMD64、GUI 子系統、圖示、Manifest、版本、靜態 DLL 相依與 PhotoCompute ABI，及 NSIS 壓縮測試、解壓後所有檔案 SHA-256 比對。負向 Smoke 以真實產物注入錯誤架構、缺少 DLL、錯誤版本與截斷資料，確認封裝不會誤放行。相依掃描包含一般與延遲匯入；動態載入的 WebView2／GPU 執行環境仍須實機驗證。

已透過 YourDesk MCP 在 Windows 10 22H2 x64（19045）、標準使用者、WebView2 154.0.4258.37 上執行實機測試。JPEG 列表與原片預覽、中文與空格路徑、ICC／EXIF、16 bit 輸出、LibRaw DNG、GPU 版本／失敗備援與 Vulkan 計算圖已通過；具體記錄見 `build/windows-native-runtime-report.json`。機器具有 Intel HD Graphics 530 與 GTX 1060 6GB；實際選用 GTX 1060，Loader 1.3.204、裝置 Vulkan 1.2.133。Nikon Z f HE／HE* NEF 仍不受目前系統與 LibRaw 支援，實測未通過。兩項要求 `VK_LAYER_KHRONOS_validation` 的除錯驗證因缺少該層而未通過，不列為 GPU 完整驗收。

封裝器輸出的 `windowsExecutionVerified`、`windowsInstallUninstallVerified`、`windowsGPUVerified` 仍為 `false`：這些欄位僅描述該次交叉編譯／封裝，不能自動承襲其他二進位的實機結果。實機報告另綁定測試安裝檔雜湊。**完整 Windows 照片處理流程仍未完成**，尚未簽署 Authenticode，也未發布 Release。

Release 前仍需依序完成：

1. 以標準使用者在乾淨 Windows 10／11 安裝，核對版本、圖示、登錄、捷徑及沒有提權。
2. 測試有／無 WebView2 與離線環境，確認缺少 Runtime 的提示及安裝後啟動；使用含繁體中文與空白的安裝路徑。
3. 同版重裝與升級；程式執行中測試占用提示及靜默非零退出；不支援架構應拒絕。
4. 安裝目錄放入額外測試檔並建立使用者設定，解除安裝後確認這些資料與照片仍存在；同時核對捷徑及解除安裝登錄已移除。
5. 補齊完整 Windows 原生影像引擎後，驗證開圖／預覽／匯出、CPU／GPU、不同驅動與跨平台影像一致性；再處理正式簽章與 Release。


## 配方跨平台驗證

Windows 與測試主機共用 `engine/cpp/render_pipeline.hpp`，保留 Swift 的階段順序、低強度原片混合、黑白及掃描順序。Vulkan 將底片、乳劑、數位風格與 HDR 放在同一計算圖；CPU 使用同一套資料作為失敗回退。LibRaw 的線性底片來源與相機原片分開保存。

數位／相機風格的色彩表由 `scripts/export-windows-style-data.py` 從現有 Swift 程式產生；65³ 線性 Float32 表採 sRGB 取樣座標。光暈、銳化、分區遮罩與 HDR 保留獨立空間處理，不烘焙進色彩表。表格插值與平台浮點差異不保證逐位元相同。更新 Swift 風格時需重跑匯出腳本；交叉編譯會檢查來源與資料雜湊，拒絕使用過期表格。

測試入口：`photo_compute_optics_verify` 比對 CPU／Vulkan、透明度與單次傳輸；`photo_compute_styles_verify` 使用真正 Swift 引擎產生的同圖金樣本，比對完整配方管線。Windows 實機另外執行全部配方、CPU 備援與 Go／WebView2 切換配方 Smoke。
