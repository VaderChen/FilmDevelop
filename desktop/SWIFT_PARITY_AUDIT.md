# Swift 舊版與 Go 新版功能移植比對

初查確認 13 項移植缺漏或行為退化，現已全部修正。問題主要在 Go 主程式的操作規則、狀態欄位與原生影像工作的銜接；既有配方相容性測試通過，仍無法涵蓋這些流程。

比對與修正日期為 2026 年 10 月 3 日。基準是同一份儲存庫內保留的 Swift 桌面實作 `PhotoStyleApp`，對照 Go／Wails 的 `desktop` 與 macOS 原生引擎；Git 基準為 `4cb05aca6a0b853208fa9a2240492c2c7a2f6222`。工作目錄包含上一輪尚未提交的效能最佳化，修正沿用這些變更。

**修正狀態**

| 編號 | 已恢復的行為 | 驗證 |
| --- | --- | --- |
| F01 | 自訂底片切回同一內建底片時，先取得原工作槽；懸停與選取共用規則。 | `TestSwiftParityCustomFilmBase` |
| F02 | AI 可用時承接曝光、HDR 強度及尚未建立的 HDR 曲線。 | `TestSwiftParityStyleExposureHDR` |
| F03 | 多選重設依完整 ID 清單處理，清除各張配方與遮罩；目前照片刷新不再中止後續批次。 | `TestSwiftParityMultiReset`、實際視窗 |
| F04 | AI 取消／取消中狀態、七個階段、完成後展開調整；等待最終預覽，拒絕取消後較晚結果。MLX 沿用舊版的開始生成／套用預覽回報。 | `TestSwiftParityAILifecycle`、`TestMLXLegacyProgress`、實際視窗 |
| F05 | 批次對話框逐張顯示檔名、張數及整批進度，包含編碼／儲存與成功／失敗統計。 | `TestSwiftParityBatchProgress`、實際視窗兩張成功／一張失敗 |
| F06 | 正負膚色暖度皆要求遮罩，已保存且有效的遮罩不再因滑桿為零而被忽略；AI 完成後嘗試主體偵測。 | `TestSwiftParitySkinWarmth`、AI 生命週期測試 |
| F07 | 鏡頭校正切換清除舊遮罩；新保存遮罩記錄鏡頭設定，工作建立時核對。 | `TestSwiftParityLensMask` |
| F08 | 儲存對話框確認後可取代既有成品；來源照片、同檔別名及已被其他操作修改的目的檔受保護。 | `TestSwiftParityExportOverwrite`、失敗／取消保留測試、實際 JPEG 連續匯出 |
| F09 | MCP 使用已保存的品質、尺寸、色彩空間、WebP、TIFF 及 EXIF 設定；色深維持原 MCP 契約或明確指定值。 | `TestSwiftParityMCPExportSettings` |
| F10 | 複製後開啟並定位新副本。 | `TestSwiftParityDuplicateSelection`、實際視窗 |
| F11 | Wails 原生拖放接回既有開檔握手，先提交尚未送出的編輯。 | `TestSwiftParityDropUsesNativeOpenHandshake`、實際視窗原生事件 |
| F12 | 選檔、拖放及列表共用副檔名清單。 | `TestImportEntrypointsShareFormats` |
| F13 | UI 與 MCP 共用匯出生命週期，恢復原有顯影對話框及 render／encode／write 回報，成功或失敗皆收尾。 | 實際 JPEG／PNG 匯出、MCP Smoke、失敗／取消測試 |

另針對外接磁碟 JPEG 的「Operation not supported」，在 macOS 不支援 `RENAME_EXCL` 時，以排他建立及有界串流複製發布成品；不覆寫同名檔案，失敗時清除本次建立的未完成檔。一般發布仍使用原子改名；串流備援不保證複製過程中的原子可見性。詳細結果、測試界線及本機成品見 [修復驗證摘要](parity-fixes-report.json) 與 [還原紀錄](RESTORATION.md)。

以下為修正前的原始發現與證據；原始行號及負向重現測試對應上述 Git 基準，不能視為目前版本仍有相同缺漏。

**初查驗證範圍與結果**

- 舊版 63 個橋接動作名稱，在新版程式中都有對應。這只證明入口存在，不能證明行為一致。
- 重新執行 `TestSwiftCompatibility` 與 `TestHiddenSwiftCompatibility`，全部通過；主要 Swift 參考檔包含 1,957 組案例，涵蓋配方正規化、編輯投影及版本相容性。
- 以 Go overlay 載入 10 組隔離重現測試，使用暫存照片與資料目錄，開啟 race detector。10 組均成功重現差異，未報告資料競爭。測試中的「通過」表示缺漏已重現，不表示功能正確。
- 以實際 macOS Wails 視窗執行 7 項畫面／橋接檢查，包含補入舊版欄位的對照組，均符合觀察結果。
- 直接取出舊 Swift 的 `PhotoBatchExportProgress` 結構執行，確認第 2／3 張、單張進度 50% 時，舊版確實輸出 `current: 2`、`progress: 0.5`。

**初查的 13 項缺漏**

| 編號 | 功能 | 修正前新版的實際差異 | 證據 |
| --- | --- | --- | --- |
| F01 | 自訂底片切回原底片 | 名稱已切回，仍保留自訂底片參數 | 隔離重現 |
| F02 | AI 可用時切換底片 | 未承接照片曝光與 HDR | 隔離重現 |
| F03 | 多選恢復預設值 | 只重設目前照片 | 隔離重現 |
| F04 | AI 分析取消與進度 | 取消按鈕隱藏，缺少階段清單與完成後展開 | 狀態重現及實際視窗 |
| F05 | 批次進度 | 進度為 0%，張數出現 undefined | 狀態重現、Swift 執行及實際視窗 |
| F06 | 膚色暖度與主體遮罩 | 配方要求遮罩，工作卻把要求關閉 | 隔離重現及原生路徑比對 |
| F07 | RAW 鏡頭校正切換 | 舊遮罩沒有失效，仍可傳給新影像 | 遮罩合約重現及原碼比對 |
| F08 | 覆寫已匯出的檔案 | 儲存對話框確認後仍遭拒絕 | 引擎用戶端重現及 UI 呼叫路徑比對 |
| F09 | MCP 匯出 | 忽略已保存的品質、色彩空間及尺寸 | 匯出工作重現 |
| F10 | 複製照片 | 建立副本後未自動開啟、定位副本 | 隔離重現及橋接檢查 |
| F11 | 拖曳匯入 | 缺少新版的拖放開檔接線 | 原碼及本機 Wails 設定比對 |
| F12 | 開啟照片對話框 | 濾掉部分舊版可選的影像與 RAW 格式 | 原碼及支援清單比對 |
| F13 | 匯出顯影動畫 | 開始、進度及完成事件未接通 | 原碼及實際視窗橋接檢查 |

F01、F02、F03、F06、F07、F09 影響照片結果或操作範圍，其餘項目涉及取消、開檔、覆寫、複製與進度回饋；本輪均已處理。

**F01 自訂底片切回原底片後仍套用自訂參數**

將 Portra 400 建成對比 73 的自訂底片，套用後再點回內建 Portra 400。舊版會還原原底片工作槽；新版的自訂選取 ID 已清除，但對比仍為 73，應還原的基準為 0。使用者看到的底片名稱與實際處理參數不一致。

新版先以 `recipeForLook` 取得 `next`，之後才還原 `customBase`，最後又以先前取得的自訂配方覆蓋同一個槽位。應將底片選取規則集中處理，先決定正確的內建基準，再套用照片共用資料；懸停預覽也應使用相同規則。

舊版：[StyleActions.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+StyleActions.swift)。新版：[library.go](../desktop/internal/application/library.go)。重現：`TestParityAuditCustomFilmBase`。

**F02 AI 可用時切換底片沒有承接曝光與 HDR**

前提為模型已啟用且可用，目標底片尚無照片分析結果。把目前曝光設為 12、HDR 設為 45，再切到 Portra 400，新版得到 0／0。Swift 會保留目前曝光，承接 HDR 強度，並在目標尚無 HDR 曲線時沿用目前曲線。

新版的 `preserveGeometry` 只移轉裁切與修復，沒有舊版依 AI 狀態及分析結果決定配方的規則。這也影響使用相同配方取得方式的底片懸停預覽。此項的曝光承接前提是「AI 可用」，不能直接推廣到沒有 AI 的情況。

舊版：[StyleActions.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+StyleActions.swift)。新版：[library.go](../desktop/internal/application/library.go)、[editing.go](../desktop/internal/application/editing.go)。重現：`TestParityAuditStyleExposureHDR`。

**F03 多選照片的恢復預設值只重設目前照片**

在照片列表選取兩張已調整照片，按「恢復預設值」。前端仍送出兩張照片的 `ids`，但新版 `resetAdjustments` 完全不讀取清單。隔離重現中，目前照片回到原片，第二張仍為 Portra 400、對比 37。

Swift 遇到多個 ID 會呼叫批次重設。新版其實已有 `batchPhotos(..., "reset", ...)`，但此入口未接上。修正應讓單張與多選入口共用既有操作，並正確處理照片紀錄、已調整標記與遮罩。

舊版：[StyleActions.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+StyleActions.swift)。新版：[app.go](../desktop/internal/application/app.go)。重現：`TestParityAuditMultiReset`。

**F04 AI 分析的取消按鈕與進度狀態沒有完整移植**

新版狀態缺少 `canCancelComputation` 與 `isCancellingComputation`，前端因此把取消按鈕隱藏。實際 Wails 視窗確認：AI 對話框顯示，但取消按鈕為 hidden；補入舊欄位後立即顯示。後端雖有取消動作，使用者無法從原有按鈕操作。

同一組狀態也漏掉 `computationItems`、`computationCompletedItems` 與 `expandAdjustments`；推論呼叫未接進度回呼，因此階段清單和分析完成後自動展開調整面板的流程也不完整。應共同還原工作生命週期與狀態契約，避免只補一個顯示旗標。

舊版：[State.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+State.swift)、[Computation.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Computation.swift)。新版：[app.go](../desktop/internal/application/app.go)、[inference.go](../desktop/internal/application/inference.go)。前端判斷：[app.js](../PhotoStyleApp/Web/app.js)。重現：`TestParityAuditAICancelState` 及 UI 報告。

**F05 批次處理的進度欄位與前端不相容**

Go 傳送零起算的 `index` 與單張 `fraction`，共用前端仍讀取 `current` 與整批 `progress`。在第 2／3 張、單張完成一半時，實際畫面顯示「0% · 第 undefined 張／共 3 張」；舊 Swift 執行結果及前端對照組均為「50% · 第 2 張／共 3 張」。

這個進度發布器由批次匯出、套用、重設與複製共用。應在統一發布點轉換契約：`current = index + 1`，`progress = (index + fraction) / total`，並保留零張與完成狀態的邊界處理。

舊版：[Saving.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Saving.swift)。新版：[organization.go](../desktop/internal/application/organization.go)。前端：[app.js](../PhotoStyleApp/Web/app.js)。重現：`TestParityAuditBatchProgress`、Swift 參考輸出及 UI 報告。

**F06 膚色暖度要求的主體遮罩被工作建立流程關閉**

把膚色暖度設為 +35 或 −35，配方層均正確產生 `detectSubject: true`，但 `App.job` 重新計算時只檢查背景模糊、美白、磨皮，結果把它改成 false。Swift 的 `requiresSubjectMask` 明確包含膚色暖度的絕對值。

原生引擎也以此旗標決定是否載入已保存的遮罩。因此問題不只是少一次偵測：已有遮罩時也可能被略過，讓膚色調整少了主體限制，並跳過依主體遮罩啟用的膚色白平衡。膚色暖度仍會執行色彩遮罩運算，不能說整個滑桿完全無效。舊版 AI 分析完成後另有主體偵測階段，新版也未完整承接。

應集中判斷配方是否需要遮罩，並區分「需要新偵測」與「沿用已有遮罩」。本次確認的是工作參數與執行路徑，沒有量化真實人像的像素誤差。

舊版：[PhotoStyle.swift](../PhotoStyleApp/PhotoStyle.swift)、[ImagePipeline.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+ImagePipeline.swift)、[Computation.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Computation.swift)。新版：[app.go](../desktop/internal/application/app.go)、[main.swift](../engine/macos/main.swift)。影響路徑：[PhotoStyleProcessor.swift](../PhotoStyleApp/PhotoStyleProcessor.swift)。重現：`TestParityAuditSkinWarmth`。

**F07 切換 RAW 鏡頭校正後仍可能沿用舊遮罩**

Swift 在鏡頭校正設定改變並成功重新解碼 RAW 後，會清除主體遮罩與偵測標記。新版只更新偏好及原圖預覽字串，沒有使遮罩失效；遮罩有效性只核對來源指紋與修復摘要，也未包含鏡頭設定。

合約重現確認關閉鏡頭校正後，舊遮罩仍被放入下一個工作。當 RAW 的鏡頭校正改變影像幾何時，便可能使景深與人像效果使用不再對齊的遮罩。原生來源快取因鏡頭設定失效，並不能排除 Go 再次傳入舊遮罩的問題。應把影響來源幾何的條件納入遮罩有效性與失效流程。

舊版：[Acceleration.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Acceleration.swift)。新版：[preferences.go](../desktop/internal/application/preferences.go)、[app.go](../desktop/internal/application/app.go)。重現：`TestParityAuditLensMask`。本次未以實拍 RAW 量化遮罩位移。

**F08 儲存對話框確認取代後仍不能覆寫既有輸出**

舊 Swift 在使用者確認儲存位置後，以 `overwrite: true` 呼叫匯出。新版對話框將相同路徑直接交給 `ExportImage`，而引擎用戶端對任何既存目標一律拒絕。隔離重現的錯誤為「匯出檔案已存在，請選擇另一個名稱」。

這影響重複匯出同一個成品檔案。新版 MCP 已有暫存輸出及安全取代機制，可整理成共用匯出策略，並繼續禁止覆寫來源照片。本次驗證了對話框後的程式路徑與拒絕分支，未自動操作原生取代確認視窗。

舊版：[Saving.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Saving.swift)。新版：[app.go](../desktop/internal/application/app.go)、[client.go](../desktop/internal/engine/client.go)。重現：`TestParityAuditExportOverwrite`。

**F09 MCP 匯出忽略已保存的品質與影像設定**

先設定 JPEG 品質 23、最長邊 640、Display P3，再以 MCP `export_image` 匯出。Swift 沿用目前匯出設定；新版建立全新預設值，只另外承接 EXIF 設定。攔取實際送出的工作可見品質 95、尺寸上限 0、sRGB。

同一條路徑也會漏用 WebP 品質／無損及 TIFF 壓縮設定。格式與位元深度原本就是 MCP 明確參數，不應混同為這項問題。修正應從目前設定建立快照，再套用 MCP 契約允許的覆寫。

舊版：[MCP.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+MCP.swift)、[Saving.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Saving.swift)。新版：[mcp.go](../desktop/internal/application/mcp.go)。重現：`TestParityAuditMCPExportSettings`。

**F10 複製照片後沒有自動開啟與定位副本**

Swift 完成複製後會選取最後建立的副本、載入照片，再送出 `handleFocusDirectoryPhoto` 將列表捲動至副本。新版只建立檔案、保存配方及重新掃描目錄。隔離重現確認資料夾已有兩個檔案，目前編輯來源仍是原片。

此外，新版橋接白名單沒有允許 `handleFocusDirectoryPhoto`；實際視窗注入該事件時回呼未執行。只補後端事件不足，必須一起恢復開檔、選取與定位流程。

舊版：[PhotoEdits.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+PhotoEdits.swift)。新版：[organization.go](../desktop/internal/application/organization.go)、[bridge.js](../desktop/frontend/bridge.js)。重現：`TestParityAuditDuplicateSelection` 及 UI 報告。

**F11 拖曳照片匯入沒有接上新版主程式**

Swift 的 WebView 註冊檔案拖放，檢查單張影像及是否可匯入，再呼叫 `openImage`。新版 Wails 設定未啟用 `DragAndDrop.EnableFileDrop`，也沒有把拖放事件接到開檔流程。本機所用 Wails 2.15.0 的此選項預設為 false；新版平台設定亦未覆寫。

共用前端仍顯示「也可以直接拖入照片」。因此操作提示保留，但應用程式的匯入路徑沒有移植。應讓拖曳、原生開檔與選檔共用驗證及未送出編輯的提交流程。本項以程式接線及依賴庫實作確認，沒有使用作業系統拖曳自動化。

舊版：[PhotoStyleWebView.swift](../PhotoStyleApp/PhotoStyleWebView.swift)。新版：[main.go](../desktop/cmd/filmdevelop-desktop/main.go)。仍存在的提示：[app.js](../PhotoStyleApp/Web/app.js)。

**F12 開啟照片對話框漏掉部分可匯入格式**

Swift 使用系統的 image／rawImage 類型。新版選檔濾鏡只列出 13 個副檔名，與新版自己的照片目錄支援清單不一致；例如 BMP、HEIF、AVIF、ORF、RW2、PEF、SRW 都未列入濾鏡。

使用者可從目錄列表找到的檔案，可能無法從「開啟照片」對話框選取。應由共同格式來源產生篩選條件，或使用與實際解碼能力一致的類型集合，避免每個入口維護不同清單。此項確認的是選檔範圍退化，未逐一驗證所有列出的 RAW 格式是否可由目前機器解碼。

舊版：[Presentation.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Presentation.swift)。新版：[app.go](../desktop/internal/application/app.go)。對照清單：[directory.go](../desktop/internal/photos/directory.go)。

**F13 匯出顯影動畫與階段進度未接通**

Swift 在單張匯出送出 `handleExportDevelopment` 的 begin、progress、complete／cancel 事件，並回報 render、encode、write 階段。新版 `ExportImage` 只設定儲存狀態、呼叫 `Render(..., nil)` 與送出完成或錯誤通知，沒有這些事件。

前端動畫程式仍存在，但橋接白名單也沒有允許該事件。實際 Wails 檢查中，白名單對照事件可正常送達，匯出動畫事件則被丟棄。因此舊版匯出時的顯影動畫與階段進度都不會由這條流程觸發。應統一匯出生命週期事件，讓成功、失敗與取消都能完整收尾。

舊版：[Saving.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+Saving.swift)。新版：[app.go](../desktop/internal/application/app.go)、[bridge.js](../desktop/frontend/bridge.js)。前端入口：[app.js](../PhotoStyleApp/Web/app.js)。證據：UI 報告。

**初查另列的兩項行為差異（已於第二輪 S01／S02 修正）**

沒有可用 AI 時，Swift 重新選取內建底片會從該底片預設值開始，保留框線、日期、適用的色彩校正及裁切；新版會沿用既有工作配方，點相同底片則直接返回。這是明確的行為差異，但可能是新版刻意保留編輯的策略，因此不與上面的已確認缺漏混算。依據：[LegacyStyleAdjustmentStore.swift](../PhotoStyleApp/LegacyStyleAdjustmentStore.swift)、[library.go](../desktop/internal/application/library.go)。

單張恢復預設值後，Swift 清除復原歷史；新版先保存歷史，允許復原這次重設。這可能是有意增加的能力，也需與既定產品要求核對。依據：[StyleActions.swift](../PhotoStyleApp/PhotoStyleWebCoordinator+StyleActions.swift)、[app.go](../desktop/internal/application/app.go)。

**驗證資料與限制**

本次隔離測試以真實 Go 應用方法執行，照片及儲存使用暫存目錄；像素渲染採測試後端，重點是實際配方、儲存紀錄、狀態及工作參數。UI 檢查則使用真實 Wails／WebKit，載入 Go 測試產生的狀態。沒有跑真實大型模型推論，也未重新執行 Windows 實機驗證；不能據此宣稱所有影像像素或硬體後端完全相容。

- [隔離重現程式](../build/swift-parity-audit-20261003/parity_test.go)
- [10 組重現結果](../build/swift-parity-audit-20261003/probes.log)
- [7 項實際視窗檢查](../build/swift-parity-audit-20261003/ui-report.json)
- [舊 Swift 批次進度執行結果](../build/swift-parity-audit-20261003/swift-batch-reference.json)
- [入口盤點](../build/swift-parity-audit-20261003/inventory.json)

原始重現程式以 overlay 加入測試套件，僅供在修正前基準重現差異；修正後應執行下列正向回歸及 Smoke：

```sh
go test -race ./internal/application ./internal/engine ./internal/photos
go test -count=1 ./internal/recipes -run 'TestSwiftCompatibility|TestHiddenSwiftCompatibility'
python3 ../engine/verification/parity-smoke.py
python3 ../engine/verification/parity-smoke.py --unsupported-rename
```

修正已集中於共用底片選取規則、工作狀態、遮罩有效性及匯出設定快照，並把操作情境轉成持續回歸測試。僅檢查入口名稱或配方參考值，無法發現初查重現的問題。
