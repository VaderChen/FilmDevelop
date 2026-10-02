# Windows x64 免安裝 ZIP

完整 Mac／Windows 發布使用 `python3 scripts/package-release.py --identity '本機簽章身分' --notary-profile '本機公證設定'`：整輪開始前清空專案 `dist` 一次，再依序產生各平台成品。更新差異見[逐版紀錄](../../CHANGELOG.md)。

正式封裝只在暫存副本移除未簽署 PE 的 DWARF 除錯區段；比較前後載入區段的位元、RVA、大小、旗標、進入點、匯入與匯出，任一差異都停止封裝。已簽署的 Microsoft Runtime 不改寫，建置目錄仍保留原始符號。清理結果記錄於套件 `build-info.json` 的 `debugCleanup`。影像查表、模型、RAW 資料與演算精度維持原值。

預設產生單一 `FilmDevelop/` 根目錄的免安裝 ZIP。完整解壓後執行 `FilmDevelop.exe`；不建立產品登錄項目、服務、捷徑或解除安裝器。Windows 10／11 x64 的版本文字持續加上 **Beta**，macOS 不變。此流程只建置本機產物，不發布 GitHub Release。

## 建置

```sh
bash scripts/build-windows-package.sh
# 原始碼未變更時，只重新封裝並驗證現有產物
bash scripts/build-windows-package.sh --no-build
```

需要 Go、Python 3.9 以上、CMake、Ninja、MinGW-w64 x64、Vulkan headers、glslangValidator、7-Zip 及 msitools 的 `msiextract`。7-Zip／msiextract 用於讀取 Microsoft 原廠 Runtime；預設 ZIP 封裝不需 NSIS。macOS 可透過 Homebrew 提供相依工具；腳本不自動安裝工具。

版本取自 `PhotoStyleApp.xcodeproj/project.pbxproj`，圖示沿用專案既有 PNG。先交叉編譯 Go GUI、CLI、獨立更新工具與 C++ 引擎，再封裝；`--no-build` 僅驗證現有二進位，不能證明它包含最近的原始碼。`--build-dir`、`--output-dir` 可調整建置與輸出目錄。

`dist/windows-x64/` 輸出：

- `FilmDevelop-<版本>-build<組建>-windows-x64-portable.zip`
- `SHA256SUMS`：ZIP 的 SHA-256。
- `verification.json`：逐檔摘要、PE 架構／DLL 相依、GUI 資源、解壓回讀及私密資料檢查。

暫存 ZIP 通過全部檢查後才替換輸出。封裝清單不包含原圖、設定、私用 `pack.command`、舊安裝器或測試檔。`files.json` 記錄套件檔案的大小與 SHA-256，不記錄自身摘要。

## 執行環境與檔案

- `FilmDevelop.exe`：Go／Wails GUI；`filmdevelop-cli.exe`：CLI；`filmdevelop-update.exe`：Go 更新工具。
- `engine/`：C++／WIC 引擎、Vulkan 計算、LibRaw、WebP、GGUF／ONNX、模型與色彩資料。
- `engine/` 同時包含 Microsoft 原廠 Visual C++ x64 Runtime。`scripts/prepare-vc-runtime-windows.py` 依 `prerequisites.json` 的固定來源與 SHA-256 取得 VC_redist，驗證內部封裝與各 DLL 的 x64／版本／簽章資料存在，再原樣複製。`Licenses/Windows/VisualCpp` 保存來源、版本、摘要與授權連結。
- Windows 10／11 內建 UCRT，但 Visual C++ Runtime 不保證存在。app-local DLL 避免要求使用者先安裝 VC Runtime；不寫入系統目錄、不覆寫系統 DLL。原廠說明見 [UCRT 部署](https://learn.microsoft.com/en-us/cpp/windows/universal-crt-deployment?view=msvc-170)與 [Visual C++ 散布](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170)。
- WebView2 Evergreen Runtime 仍為外部相依；缺少或過舊時由既有 Microsoft 流程提示安裝。離線環境應預先部署官方 x64 Runtime。
- Vulkan 由顯示卡驅動提供，套件不含 GPU 驅動。系統計算先探測 Vulkan，無法使用時回退 CPU。
- 設定、照片調整與 WebView2 快取仍位於 `%APPDATA%\FilmDevelop`；`FILMDEVELOP_DATA_DIR` 可覆寫。免安裝指程式不需安裝，不代表資料全部寫在隨身碟。
- 第三方授權在 `Licenses`。Microsoft 原廠 DLL 保留原簽章；FilmDevelop 執行檔尚未簽 Authenticode。ZIP 不保證消除瀏覽器或 Windows 的來源提示。

## 更新與資料保留

Windows「檢查更新」優先尋找 `windows-x64-portable.zip`，只有沒有 ZIP 才相容舊 `windows-x64-setup.exe` Release。ZIP 存在但摘要無效時停止，不回退到其他檔案。macOS 的 DMG 與一次性 FilmYourPhoto 識別移轉維持原流程。

更新先驗證 GitHub 下載摘要、產品／版本／x64、每個檔案的 SHA-256，再將獨立更新工具放在程式目錄旁。舊主程式保存資料、更新工具確認交接後，主程式結束。更新工具等待舊程序及工作程序釋放檔案，搬移舊目錄作為備份，再啟動新版。新版與影像引擎成功啟動才確認；失敗會還原並啟動舊版。

未列入舊套件清單的使用者檔案會保留；與新版檔案同名時停止並還原。符號連結／接合點、無法驗證的套件及不可寫入的位置不自動更新，可手動解壓至新資料夾。更新需要程式目錄及上層目錄的寫入權限；有其他程序占用時不強制關閉它們。工作紀錄保留在同層 `.filmdevelop-update-*`；成功後移除舊程式備份，失敗時保留診斷資料。

**已發布的舊 Windows 客戶端只認 setup EXE，無法自行發現 ZIP。** 第一次改用免安裝版需手動下載，完整解壓至新的資料夾並執行；沿用 `%APPDATA%\FilmDevelop` 的設定與編輯資料。之後可在新版內更新。不要直接覆蓋正在執行的舊安裝目錄。

## 相容入口與驗證

`build-windows-installer.sh` 保留為相容入口，但預設同樣建立 ZIP。只有明確使用 `--format installer` 才建立舊 NSIS 安裝檔；該模式另外需要 NSIS，使用 `README-installer.txt` 與舊 Runtime 前置安裝流程。一般交付不需此選項。

```sh
go -C desktop test -race ./internal/updater ./internal/application
python3 engine/verification/windows-installer-smoke.py
python3 engine/verification/inspect-windows.py build/windows-cross
```

更新 Smoke 涵蓋 ZIP 路徑穿越、重複檔名、錯誤版本、竄改、使用者檔案衝突與還原。歷次 Windows 10 x64、GTX 1060 的影像／UI／GPU 驗證見[功能恢復紀錄](../../desktop/RESTORATION.md)；舊測試不視為此次封裝已通過實機。Windows 11、乾淨系統、其他 GPU 仍需擴大驗證。

Nikon HE／HE* 與 GoPro GPR 直接 RAW 解碼仍有缺口；主體、景深、降噪及字形可能與 Apple 框架有差異。

## 配方跨平台驗證

Windows 與測試主機共用 `engine/cpp/render_pipeline.hpp`，保留 Swift 的階段順序、低強度原片混合、黑白及掃描順序。Vulkan 將底片、乳劑、數位風格與 HDR 放在同一計算圖；CPU 使用同一套資料作為失敗回退。LibRaw 的線性底片來源與相機原片分開保存。

數位／相機風格的色彩表由 `scripts/export-windows-style-data.py` 從現有 Swift 程式產生；65³ 線性 Float32 表採 sRGB 取樣座標。光暈、銳化、分區遮罩與 HDR 保留獨立空間處理，不烘焙進色彩表。表格插值與平台浮點差異不保證逐位元相同。更新 Swift 風格時需重跑匯出腳本；交叉編譯會檢查來源與資料雜湊，拒絕使用過期表格。

測試入口：`photo_compute_optics_verify` 比對 CPU／Vulkan、透明度與單次傳輸；`photo_compute_styles_verify` 使用真正 Swift 引擎產生的同圖金樣本，比對完整配方管線。Windows 實機另外執行全部配方、CPU 備援與 Go／WebView2 切換配方 Smoke。
