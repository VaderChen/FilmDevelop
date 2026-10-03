# RAW 跨平台解碼驗證

下列矩陣為 2026-10-02 的直接解碼基線。2026-10-03 新增的自動補充解碼與官方下載流程，見 [部署、授權及重跑說明](supplemental-decoder.md)。

基線日期：2026-10-02。以正式 PhotoRAW C 介面及混合版引擎測試，不將讀到 EXIF、內嵌 JPEG 或縮圖視為完成 RAW 解碼。

## 樣本與環境

共 44 份來源檔，涵蓋 17 個相機品牌、31 款機型：本輪從 [raw.pixls.us](https://raw.pixls.us/) 選取 36 份 CC0 樣本，再加入本機既有 8 份。36 份公開樣本中包含 3 份 HDRMerge 浮點 DNG 與 1 份 Adobe 有損 JPEG DNG；這些是衍生格式樣本，不冒稱相機直接輸出的原始檔。

公開清單 [corpus.json](corpus.json) 固定下載網址、壓縮模式、授權與 SHA-256。原始檔只放在忽略提交的 `build`，私有照片只在本機與使用者授權的 Windows 測試機處理。每次測試都核對原檔 SHA-256。

| 品牌 | 機型與覆蓋重點 |
| --- | --- |
| Canon | EOS D30、7D、5D III／IV、R、R5 II、R6 III；CRW、CR2、CR3、不同壓縮模式 |
| Nikon | D70、Z8、Zf；傳統 NEF、無損壓縮、HE／HE* |
| Sony | A100、A7 III、A7 IV；早期 ARW、壓縮與無損中尺寸 |
| Fujifilm | X-T1、X-T5；X-Trans、壓縮／未壓縮 |
| Panasonic | G10、S1R II |
| Pentax／Ricoh | K10D、K-3 III、GR III；PEF、DNG |
| Sigma | DP1、DP2 Merrill；不同世代 X3F |
| Olympus／OM System | E-1、OM-3 |
| Leica／Hasselblad／Phase One | M8、H4D-40、IQ140；DNG、3FR、TIFF 容器 RAW |
| Minolta／Samsung | Dynax 7D、NX1 |
| Apple／GoPro | iPhone 12 Pro ProRAW、HERO5 Black GPR |
| DNG 衍生格式 | 16／24／32 位元浮點 Deflate DNG、有損 JPEG DNG |

macOS 為 Apple Silicon、macOS 27.0（26A428）；Windows 為 x64、Windows 10 22H2（19045）、24 GiB RAM、GTX 1060 6 GB。Windows 測試透過 YourDesk 在使用者電腦執行，使用隔離的引擎與測試資料目錄。系統解析結果只代表這兩台機器的實際 codec，不能推論所有作業系統版本。

## 已修正

1. 兩端固定 LibRaw 0.22.2、zlib 1.3.2、libjpeg-turbo 3.1.4.1，啟用 `USE_ZLIB`、`USE_JPEG`、`USE_JPEG8`、`USE_X3FTOOLS`。修正 Windows 缺少 Deflate，以及兩端缺少 JPEG DNG／X3F 的建置差異；相依庫靜態連結並附帶授權，不增加執行期 DLL。
2. RAW 編譯關閉 fast-math 與浮點 FMA 合併，降低不同 CPU／編譯器的數值差異。JPEG 相依庫固定不啟用 SIMD，使用相同的解碼路徑。
3. macOS 已知 RAW 不再於解碼失敗後落到一般點陣圖解析，也不以相機內嵌 JPEG 代替編輯來源。原生解碼失敗或產生與相機預覽矛盾的近黑結果時，嘗試正式軟體 RAW 解碼。
4. Windows 排除一般 TIFF／JPEG／PNG 等 WIC codec 冒充 RAW；也依 [Microsoft RAW codec 契約](https://learn.microsoft.com/en-us/windows/win32/wic/-wic-imp-iwicdevelopraw) 檢查影格是否提供 `IWICDevelopRaw`。只提供內嵌影像的 codec 可供列表使用，編輯則退回 LibRaw。本輪因此修正 X-T1 被讀成 1920×1280 預覽，以及 iPhone ProRAW 系統 codec 兩次超過 180 秒仍未完成的問題。修正後分別從完整 4934×3296、3024×4032 感光影像顯影，約 17.0、5.2 秒完成。
5. TIFF 容器先用 RAW 中介層辨識，避免 Phase One RAW 被當成小尺寸 TIFF 預覽；RAW 感光尺寸不再被 WIC 的 IFD0 縮圖尺寸覆蓋。
6. Go 匯入清單補上 Canon CRW；macOS 引擎回傳實際解碼後端與 fallback 註記，從來源快取取得資訊，避免縮放後遺失。

預設仍使用系統原生解析，設定持久化與平台硬體加速的既有流程保留。跨平台比對時明確指定共用軟體解碼器，不能把 Apple 與 Windows 原生解碼器當成同一套色彩演算法。

## 本輪結果

完整機器可讀證據保存在 `build/raw-compatibility-20261002/`：`report.json` 為總表，`comparison.json`／`comparison-half.json`／`comparison-converted.json` 保留每份樣本的數值，`manifest.json` 記錄完整 44 份清單及原檔雜湊。

| 驗證 | macOS | Windows x64 |
| --- | --- | --- |
| 修改前，共用 RAW 中介層完整解碼 | 35／44 | 32／44 |
| 修改後，共用 RAW 中介層完整解碼 | 38／44 | 38／44 |
| 正式引擎，系統／軟體各跑一次 | 86／88 | 76／88 |
| 選定 6 份半尺寸解碼 | 6／6 | 6／6 |
| 將不支援的 6 份轉成 DNG 後解碼 | 6／6 | 6／6 |
| 偽裝 RAW／截斷 RAW 拒絕測試 | 4／4 符合預期 | 4／4 符合預期 |

macOS 共用中介層剩下 5 份 Nikon HE／HE* 及 1 份 GoPro GPR 不支援。macOS 系統引擎能解開這 5 份 Nikon，因此正式引擎成功 43／44 份；指定 software 時這 5 份會明確標示改用 system，不計為 LibRaw 支援 HE。GoPro 原檔在兩個 macOS 模式都回報失敗。

Windows 在補上 WIC RAW 介面檢查後，完整重跑 system 模式的 44 份：38 份透過軟體 fallback 成功、6 份明確失敗，沒有逾時；所有原檔雜湊不變。software 模式的 44 份使用相同 RAW 實作，沿用 WIC 支路修改前已完成的驗證。6 份轉檔 DNG 的 system 模式也重跑通過。這台 Windows 登錄的 codec 未提供所需 RAW 顯影介面，不能外推成所有 Windows 的系統 codec 均不可用；計算加速仍使用實機 Vulkan。

來源解析度的回歸檢查在修改前會抓出 X-T1 縮圖，修改後 MAC、WIN 各 76 個具共用 RAW 參考的成功請求全部通過；Windows 轉檔 DNG 的 12 個請求也通過。5 份 macOS 原生可解、共用解碼器不可解的 Nikon 不納入這項參考比對。另完成 macOS UI 35 項、引擎 15 項、Windows 編輯／JPEG、TIFF、PNG、WebP 讀寫 31 項，以及 Windows 封裝 11 項 Smoke，均通過。

已重建 macOS DMG 與 Windows x64 `1.26.0924 build 1107 Beta` 安裝檔，Windows 封裝共 156 個檔案通過架構及解壓雜湊檢查，內含引擎與本輪實機測試的檔案 SHA 相同。未發布 Release；本輪 Windows 測試在隔離目錄執行，尚未覆蓋正式安裝位置或重跑安裝／解除安裝。

比對標準為：完整 RAW 尺寸與相機中繼資料相同、全圖沒有 NaN／Infinity、固定 64×64 RGB 網格的線性值最大差 ≤ 2／65535、顯示 RGB8 最大差 ≤ 1，以及全圖各通道平均值與平方平均值最大差 ≤ 1e-7。另記錄完整影像的 FNV-1a 指紋；指紋不同時，取樣容差不代表每一個像素都相同。解碼失敗列為不支援，不列為通過。

同一套嚴格容差下，修改前兩端共同可解的 32 份只有 24 份通過；修改後 38 份共同可解，37 份通過（這 37 份的取樣差皆為 0）。剩下 X-T1 在 4096 個取樣位置中有 2 個位置（6 個 RGB 分量）不同，最大線性差 0.00161743（0…1 的約 0.162%），取樣顯示 RGB8 差為 0。其全圖平均值最大差約 1.88e-8，平方平均值最大差約 1.90e-8。這項保留為未達嚴格容差，未放寬門檻；尚未完成去馬賽克內部算術差異的根因定位，不宣稱逐像素完全一致。

完整解析的 38 份中，6 份的全圖線性／顯示指紋都相同。半尺寸 6 份全部通過且全圖指紋相同；轉成 DNG 的 6 份全部通過，取樣差為 0、全圖平均值差 ≤ 1.93e-9，但全圖指紋不同。這些結論只適用於清單中的檔案、模式與版本。

目前流程的線性緩衝雖使用 Float32，但 LibRaw 輸入是已截斷的 RGB16（0…1），尚未保留場景線性的負值與超過 1 的高光。浮點 DNG「可解碼」不表示 HDR 範圍已完整保留。色彩 mapping 的既有 11 機型校色驗證也不能外推到這輪所有機型。

## 缺失解碼器的補齊方式

| 缺口 | 可行方式與目前狀態 |
| --- | --- |
| Deflate／JPEG DNG、Sigma X3F | 本輪已補齊建置選項與相依庫，並以實際照片驗證。 |
| Nikon HE／HE* | LibRaw 官方仍列為不支援。短期可使用 Adobe DNG Converter 轉成保留感光資料的 DNG；本輪已實際轉換 5 份，未改寫原檔。長期可評估 Nikon NEF/NRW Image SDK，需取得授權套件後驗證 HE 模式與平台支援。 |
| GoPro GPR／VC-5 | 本輪已實際用 Adobe DNG Converter 轉換 1 份。若要原生直接解碼，可於共用 C++ 中介層整合 GoPro GPR SDK 及其 DNG 相依，但尚未編譯、整合或宣稱已支援。 |
| JPEG XL／Enhanced DNG | LibRaw 的 DNG SDK 介面可作為擴充點，需建置新版 Adobe DNG SDK 及所需 JPEG XL 等相依，再加入對應樣本；本輪尚未驗證這些格式。單純加入 DNG SDK 不會讓 proprietary Nikon HE NEF 自動可解。 |
| 後續新機型／韌體模式 | 更新固定版本的 LibRaw／codec，將新檔的壓縮模式與 SHA 納入同一矩陣；不能只用機型名稱或相機支援清單判定所有模式可用。 |

LibRaw 的[機型清單](https://www.libraw.org/supported-cameras) 以完整功能建置為前提，並明示 Nikon HE／HE* 的限制。現有相機被列在支援清單不代表缺少可選相依庫的程式也能解碼。

Adobe 官方提供 [DNG Converter](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html) 與 [命令列說明](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section/download-1/dng_converter_commandline.pdf)。本輪使用經 Adobe 簽章驗證的 macOS 18.7 版，以 `-c -dng1.4 -p0 -d OUTPUT INPUT` 產生獨立 DNG；6 份都通過結構檢查，包含 CFA mosaic RAW，並在兩端共用解碼器通過測試。未使用會去馬賽克的線性 DNG 選項。沒有把 Adobe 程式綁入安裝檔，也尚未整合成 App 自動 fallback；Windows Converter 本身尚未實測，Windows 使用的是同一批 macOS 產出的 DNG。轉檔可能改變廠商私有 metadata，仍須保存原檔。

轉檔後的 Nikon Z8 感光尺寸為 8280×5520、Zf 為 6064×4040；本機 Apple 原生路徑分別為 8256×5504、6048×4032。兩者有效區域裁切不同，因此不能把成功讀取 DNG 說成與原生 NEF 全部輸出一致。

Nikon 提供 [Image SDK 申請](https://sdk.nikonimaging.com/apply/)，但官方 [2025-11-13 更新公告](https://sdk.nikonimaging.com/information/en/) 已結束 NEF/NRW Image SDK 的 Windows 10 支援。本輪測試機是 Windows 10，不能直接承諾最新版 SDK 可用；必須取得符合部署平台與再散布授權的版本，再做真實 HE 檔測試。沒有代使用者申請 SDK 或接受授權。

[GoPro GPR SDK](https://github.com/gopro/gpr) 提供 C API，實作為 C/C++，適合包在 PhotoRAW 介面後；其程式與 bundled DNG 相依的授權應分別確認。[LibRaw DNG SDK 整合說明](https://github.com/LibRaw/LibRaw/blob/master/README.DNGSDK.txt) 區分 Deflate、JPEG、JPEG XL／Enhanced DNG 所需的解碼相依；[Adobe DNG SDK 官方頁](https://www.adobe.com/support/downloads/dng/dng_sdk.html) 可取得目前版本。

若接入外部轉檔器，建議由 Go 統一偵測可用後端、排程與取消，用原檔 SHA＋轉檔器版本＋選項作快取鍵；Swift／C++ 仍負責各平台原生解碼與硬體計算。轉檔只產生快取副本，實際後端寫入結果，兩端再走相同 PhotoRAW C 介面，避免 UI 或平台程式各自維護一套判斷。

## 重跑方式

以下由專案根目錄執行；需 Python 3、Xcode 工具鏈、CMake／Ninja、MinGW x64，正式 RAW 建置會下載並驗證固定版本來源。

```sh
python3 engine/verification/raw/download.py build/raw-check/samples
cp engine/verification/raw/corpus.json build/raw-check/manifest.json
bash scripts/build-raw-macos.sh
python3 scripts/build-raw-windows.py build/windows-cross/raw
python3 engine/verification/raw/build-probe.py macos-arm64 build/raw-check/probe-macos
python3 engine/verification/raw/build-probe.py windows-x64 build/raw-check/probe-windows.exe
python3 engine/verification/raw/run.py build/raw-check/probe-macos build/raw-check/manifest.json build/raw-check/samples Vendor/PhotoRAW/macos/RAWMapping build/raw-check/macos
```

將 `probe-windows.exe`、`manifest.json`、`samples`、`RAWMapping` 與 `run-windows.ps1` 放在同一個 Windows 測試目錄，於 PowerShell 執行：

```powershell
.\run-windows.ps1 -Probe probe-windows.exe -Output windows
```

測試腳本以 UTF-8 BOM 保存，供 Windows PowerShell 5 正確讀取中文註解。每張以獨立行程限制 180 秒。將 Windows 結果帶回後比對：

```sh
python3 engine/verification/raw/compare.py build/raw-check/manifest.json build/raw-check/macos build/raw-check/windows build/raw-check/comparison.json
```

`validate-engine.py 引擎報告 RAW探針目錄 輸出報告` 會另外比對來源像素數，將少於完整參考一半或明確標記為內嵌預覽的結果列為失敗；這是防止縮圖冒充 RAW 的保守檢查，不等於逐像素或色彩驗證。它能重現修改前 X-T1 的錯誤來源。

加上 `run.py --half` 或 `run-windows.ps1 -Half` 可測半尺寸，必須兩端使用相同模式。正式引擎測試以 `run-engine.py --help`、`run-engine-windows.ps1` 的參數指定引擎、同一清單與相同 neutral recipe；結果會同時記錄請求模式、實際後端、輸出 PNG 尺寸及原檔雜湊。macOS 與 Windows 目前編輯預覽的半尺寸策略不同，因此預覽 PNG 不作為共用解碼器逐像素等價的判準。
