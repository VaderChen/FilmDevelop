# 補充 RAW 解碼器與部署

日期：2026-10-03。本流程補足「LibRaw 已辨識，但目前建置缺少感光資料解碼器」的 RAW。依解碼器能力回覆處理，不以相機型號或單一 NEF 檔名建立特例。

## Adobe 的取得與授權界線

Adobe 將 [DNG Converter](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html) 提供為免費工具，並公布[命令列自動化介面](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section/download-1/dng_converter_commandline.pdf)。因此本專案採用使用者自行取得、安裝的 Converter 作為本機轉換工具。

未找到將 Converter 綁入第三方產品、鏡像下載或拆分其執行檔／DLL 重新散布的授權。實際檢查 Adobe 18.7 macOS 安裝包隨附的 `Resources/en.txt`：第 2.1.6 節談的是內部網路部署，第 4.6 節限制轉移權利；第 16 節沒有 DNG Converter 再散布例外。Adobe 的[下載授權頁](https://www.adobe.com/support/downloads/license.html) 也指出，個別下載檔案隨附的協議優先。因此不能因為「免費」或 DNG 格式／SDK 開放，就推定 Converter 可隨 FilmDevelop 發布。

產品部署方式：

1. FilmDevelop 保留既有系統解析及 LibRaw；正常可解的檔案不需 Adobe。
2. 遇到明確缺少的 RAW 解碼器時，偵測標準安裝位置的 DNG Converter。
3. 未安裝時，自動顯示確認對話框；按「Adobe 官方下載」後，以系統預設瀏覽器開啟 Adobe 官方下載頁。取消後可從照片下方「安裝 RAW 解碼器」重新開啟，同一張照片重試不反覆彈出。此確認流程自 build 1026 提供；build 0924 需自行點選下方入口。
4. 使用者完成原廠授權及安裝後，按「重新偵測」或重新載入預覽即可繼續，不必重開 FilmDevelop。
5. FilmDevelop 的 DMG、Windows 免安裝 ZIP 與 GitHub 均不包含 Adobe 安裝包、執行檔、DLL、相機設定檔或鏡像副本，也不代按授權同意、不靜默安裝。

18.7 官方要求 Windows 10 22H2／Windows 11 21H2 以上（x64 CPU 需 SSE 4.2），macOS 13 以上。這是補充工具的需求；下載時仍以 Adobe 當下提供版本的需求為準。本輪 Windows 執行測試採 x64，沒有將交叉編譯視為實機通過。

## 處理方式

Go 宿主在收到 `rawConversionRequired` 後，才呼叫外部 Converter。指定 `-c -dng1.4 -p0` 建立無損壓縮 DNG；不指定去馬賽克、縮小或有損選項。轉換後仍由兩端相同的 PhotoRAW／LibRaw 路徑完成感光資料解碼與既有顯影。

轉換只讀取原檔快照，在私人暫存目錄寫入衍生檔。檢查轉換結果為可解 DNG、保留來源 CFA mosaic 及完整有效尺寸後，才交給原生引擎；相機內嵌 JPEG 不得冒充編輯來源。原圖識別、調整、分類、分級與匯出 EXIF 仍使用原檔。DNG 可能不含完整廠商私有 metadata，因此不以轉檔取代原檔。

快取由來源內容 SHA-256、來源格式、所選後端、Converter 執行檔指紋與轉換選項識別。最多保留 8 張／512 MiB，退出時清理；相同照片的預覽、分析、修復與匯出可共用。來源或轉檔器變更、快取損壞時不沿用舊結果。轉換支援取消與逾時；取消或失敗不發布部分成品。

列表優先沿用相機內嵌縮圖；若系統連縮圖也無法取得，再確認是已辨識且缺少解碼器的 RAW，交由相同補充流程處理。縮圖回覆維持原有三欄契約並通過 Go 的格式、尺寸與黑邊正規化檢查。縮圖使用獨立工作佇列與 Client，因此其轉換快取不與編輯 Client 共用；各自重複請求可沿用快取。重新偵測也會清除列表先前失敗的標記，安裝後不用重啟程式即可補回可見縮圖。

一般預覽維持「列表縮圖 → 已套參數的編輯圖 → 逐步顯示完成影像」，等待提示放在照片下方。若目前照片明確回報缺少補充解碼器，才自動開啟上述確認；背景列表縮圖不觸發。若已有其他對話框，等待該操作結束並重新確認目前照片是否仍需要解碼器。

預設系統解析保持不變。macOS 明確選擇軟體解析遇到缺口時，會要求補充解碼器，避免悄悄使用另一套色彩處理；使用系統解析則仍可直接解碼 Apple 支援的 NEF。

## 其他解碼器與限制

- Nikon HE／HE*：LibRaw 0.22 [官方清單](https://www.libraw.org/supported-cameras) 仍排除這些壓縮模式。已接上上述共同轉換流程。
- GoPro GPR／VC-5：同樣使用共同流程，沒有將 DNG 容器排除。若要完全內建，後續可整合 [GoPro GPR SDK](https://github.com/gopro/gpr) 及其相依授權；目前尚未整合該 SDK。
- JPEG XL／Enhanced DNG：可延用已辨識缺少解碼器的入口；本輪沒有對應樣本，不能宣稱已驗收。直接解碼可評估 [LibRaw DNG SDK 介面](https://github.com/LibRaw/LibRaw/blob/master/README.DNGSDK.txt)。
- Nikon 原廠 [NEF/NRW SDK](https://sdk.nikonimaging.com/apply/) 需申請與授權；[更新公告](https://sdk.nikonimaging.com/information/en/) 已於 2025-11-13 結束新版 SDK 的 Windows 10 支援。不能直接作為本輪 Windows 10 的替代品。
- [intoPIX FastTicoRAW](https://www.intopix.com/fasttico-raw-cpu-gpu-sdks) 提供 CPU／GPU SDK，但需向供應商取得 SDK 與商用部署條件；目前沒有已取得、可直接替換的套件。

未知相機、損毀資料、超過資源限制或 Adobe 本身也不支援的來源仍會明確失敗；不把它們列為可解。LibRaw 現有 RGB16／高光範圍限制與 Apple 原生有效裁切差異，也不會因為加入轉換器而消失。完整背景見 [RAW 驗證紀錄](README.md)。

## 本輪驗證結果

使用兩平台各自的 Adobe DNG Converter 18.7，不把 Mac 轉好的 DNG 當成 Windows 轉換通過。Windows 原廠執行檔的 Authenticode 簽章為 `Adobe Inc.`、狀態 `Valid`。所有下載安裝包、相機檔、完整測試清單與成品僅留在忽略提交的私人測試目錄；公開摘要見 [supplemental-results.json](supplemental-results.json)。

| 驗證範圍 | 結果 |
| --- | --- |
| Mac，共同軟體路徑 | 47 張 RAW × 首次預覽／暖快取／完整解碼後匯出，共 141／141 通過；14 張需要補充轉換。 |
| Mac，預設系統路徑的 GPR | 首次預覽、暖快取與匯出 3／3 通過。 |
| Windows 10 22H2 x64，共同軟體路徑 | 20 張 × 3 次，共 60／60 通過；含 14 張補充轉換與 6 張既有直接解碼對照。 |
| Windows，預設系統路徑 | 14 張缺失格式 × 3 次，共 42／42 通過；結果明確回報補充轉換與軟體解碼。 |
| Mac／Windows 列表 GPR 縮圖 | 兩端皆通過實際宿主嚴格契約、暖快取、原檔保存與結束清理。 |
| 匯出拍攝 EXIF | Mac 17 張；Windows 17 張、合計 31 份匯出通過。檢查品牌、機型、拍攝時間、曝光、光圈、ISO、焦距，以及重設後的輸出方向與尺寸。 |
| build 0924 UI 與失敗路徑 | 真實 Mac Wails 47 項 Smoke 通過；缺少 Converter 時不自動開對話框，保留已有照片，提供官方下載及重新偵測。實際轉換取消、缺少工具、快取內容變更／損壞亦通過。 |

Windows 的 102 次工作均與 Mac 核對原始檔雜湊及完整感光尺寸；完整解碼的匯出尺寸一致。測試成功並非只檢查「有生成檔案」：同時要求完整感光資料、實際軟體後端、正確轉換路由、暖快取命中及原檔不變。

20 張共同成品採原片配方、sRGB PNG16、最長邊 384 px，比對全圖 RGB 通道值。各張平均絕對差為 6.28–14.20／65535（約 0.010–0.022%，相當於 RGB8 的 0.024–0.055 階）；各張第 99 百分位差最大為 363／65535，局部最大差為 3343／65535。14 張補充解碼成品的局部最大差為 2111／65535。這是經各平台顯影、縮放與編碼後的成品差異，尚未將每一處差異歸因於 Converter 或後段運算，因此不宣稱逐像素相同，也不拿平均值遮蔽局部最大值。

直接解碼對照中的 Nikon D70，在半尺寸預覽仍有 1 px 高度捨入差（Mac 255、Windows 254）；完整感光尺寸與匯出尺寸一致。此既有預覽策略差異未列為已修正。本輪未執行 Windows 11 實機測試，也未驗收所有 Adobe 支援機型。

相關 Go race／vet、JavaScript 語法與共用契約檢查通過；Mac 正式桌面建置及簽章檢查、Windows x64 原生引擎與 Go 桌面建置通過。上述為封裝前的功能驗證；build 0924 的正式封裝與發布驗證另記於 [桌面驗證紀錄](../../../desktop/RESTORATION.md)。

## 安裝確認流程修正（1.26.1003 build 1026）

Mac 與 Windows 10 各以真實 Nikon HE NEF 驗證 3 項桌面 Smoke：未安裝 Converter 時自動確認、取消及重試不反覆提示、手動重開後確認並使用預設瀏覽器開啟官方下載頁。Go 測試另驗證現有對話框等待、過期照片不得開啟網頁，以及成功解碼或無關錯誤不出現安裝提示。本輪未變更 RAW 轉換或像素處理；上節 build 0924 的解碼與成品數據保留原驗證範圍。

## 重跑補充流程

先以標準原廠安裝位置安裝 Converter。開發測試也可明確設定 `FILMDEVELOP_DNG_CONVERTER` 指向自己的原廠執行檔；只接受完整路徑，不從目前工作目錄或 PATH 自動搜尋。

準備 JSON 清單，包含 `cases`（每筆 `id`、`path`、`conversion`）與完整 `recipe`。`conversion` 表示該樣本是否應經過補充轉換。照片路徑使用測試機的私人清單，不提交至 Git。

```sh
FILMDEVELOP_RAW_SMOKE_MANIFEST="$PWD/build/raw-check/manifest.json" \
FILMDEVELOP_NATIVE_SMOKE_ENGINE="$PWD/build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine" \
FILMDEVELOP_RAW_SMOKE_OUTPUT="$PWD/build/raw-check/output" \
go -C desktop test ./internal/engine -run '^TestRAWConversionNativeSmoke$' -count=1 -v
```

Windows 使用相同 Go 測試建置執行檔，再於實機設定上述環境變數及各自的路徑，執行 `engine-tests.exe -test.run=^TestRAWConversionNativeSmoke$ -test.v`。每張依序做首次預覽、暖快取預覽、完整解析後匯出；檢查實際解碼後端、原檔 SHA-256 不變與快取清理。兩端一般預覽的半尺寸策略不同，跨平台像素比對使用完整解析的匯出。

清單可選填 `backend` 為 `system` 或 `software`，省略時使用 `software`。系統模式僅將需要補充轉換的樣本列入此測試；這個測試會確認實際走到共同 LibRaw 路徑，而非將平台原生解碼器的不同結果混為同一基準。

另將 `FILMDEVELOP_RAW_THUMBNAIL_SMOKE_INPUT` 指向沒有可用內嵌縮圖的 RAW，執行 `TestRAWSupplementalThumbnailNativeSmoke`，可驗證真正列表服務的縮圖契約、重複轉換避免、原檔不變與關閉清理。
