# Swift 移植第二輪比對與修正

本輪以儲存庫保留的 Swift 桌面實作，逐項追查 Go／Wails 的動作入口、狀態回覆、照片紀錄、失敗恢復與共用前端。另確認 12 項尚未正確移植的行為，已直接修正；[第一輪 F01～F13](SWIFT_PARITY_AUDIT.md) 僅作回歸，不重複計入。Windows AI 的格式與配對問題另列為 W01、W02。

發佈版本為 `1.26.1003 build 1300`，相較已發布的 `build 1109`。第一輪尚未發布的修正與宿主配置最佳化一併納入，既有影像運算公式、版型與顯影動畫不變。

| 編號 | 修正前的差異 | 修正後與 Swift 一致的行為 | Swift 依據 |
| --- | --- | --- | --- |
| S01 | 無 AI 時沿用修改後的工作槽，同款底片重選直接返回。 | 內建底片重選回到顯影預設，保留框線、日期、適用的校正與裁切；自訂底片重選重新套用保存配方。懸停與選取共用規則。 | `LegacyStyleAdjustmentStore.defaultAdjustment`、`StyleActions.adjustmentForSelectingStyle` |
| S02 | 恢復預設仍可復原，過期底片的重設訊息也會生效。 | 單張及多張重設清除目前照片的復原／重做／手勢歷史，忽略過期底片要求。 | `StyleActions.resetAdjustments`、`PhotoEdits.performPhotoRecipeOperation` |
| S03 | 預覽重試可能取回同一份快取，影像差量又省略相同內容。 | 取消舊工作、清除成品快取，重新渲染及重送影像；一般預覽仍使用快取。 | `Bridge` 的 `retryPreview` |
| S04 | 修復取消沒有等待狀態，晚到進度會覆蓋取消提示；忙碌時缺少準備確認。 | 顯示取消中並停用重複取消，忽略晚到進度；所有準備要求都有成功或失敗回覆。 | `Repair.cancelRepairBrush`、`Bridge` 的修復準備分支 |
| S05 | 直式照片仍顯示 3:2、4:3、16:9。 | 依原始照片方向顯示 2:3、3:4、9:16，不修改共用比例目錄。 | `CropAspectRatio.title(for:)` |
| S06 | 遷移的提示詞語言固定不變，使用者改介面語言後 AI 仍用舊語言。 | 首次移轉仍尊重既有偏好；明確改語言後，AI 提示詞與系統選單使用新語言或系統語言。 | `StyleActions.setLanguage` |
| S07 | 首次安裝 PNG 預設為 16-bit。 | 恢復 PNG 8-bit 預設，已保存的 16-bit 選擇維持不變。 | `Saving.PhotoExportSettings` |
| S08 | 刪除底片後，復原、重做或重開照片可恢復失效的底片身分。 | 清除歷史中的失效身分，載入照片及還原歷史時核對底片存在與基底；照片調整參數保留。 | `StyleActions.deleteCustomFilm`、`ImagePipeline` 照片還原 |
| S09 | 儲存自訂底片只新增到庫，未選取，也未保存選取身分。 | 儲存後立即選取，保留原工作基底，記錄復原並保存照片身分；拒絕過期命名對話框。 | `StyleActions.promptToSaveCustomFilm` |
| S10 | 拷貝底片增加命名對話框，完成後也未套用副本。 | 直接產生不重複的副本名稱並套用，名稱長度依 Unicode 字素計算。 | `StyleActions.performCustomFilmMenu`、`CustomFilmStore.duplicate` |
| S11 | 底片 JSON 匯出在系統對話框確認取代後仍遭拒絕。 | 完整寫入暫存檔後取代，失敗保留原檔，拒絕連結、非一般檔案及目的檔競爭修改。 | `StyleActions.exportCustomFilm` |
| S12 | RAW 解析器或鏡頭校正切換前就保存設定，失敗時沒有恢復。 | 兩種設定共用交易，預覽成功才保存；失敗恢復解析器、鏡頭設定、原圖與遮罩，再更新預覽。 | `Acceleration.reloadRAWConfiguration` |

對應實作主要位於 `internal/application` 的 `library.go`、`film_lifecycle.go`、`editing.go`、`repair.go`、`preferences.go`、`raw_configuration.go` 與 `app.go`，由 [第二輪回歸測試](internal/application/parity_second_test.go) 驗證。

## Windows AI：W01

後端原本依平台使用 GGUF，但共用前端的下載頁仍預設 MLX；後端也允許不支援 MLX 的平台完成查詢及下載，因此檔案下載成功後才被列為「無法使用」。

修正後 Windows 的下載格式及本機模型選單直接隱藏 MLX，使用 GGUF；後端同步阻止不支援平台的 MLX 查詢／下載。已下載的 MLX 檔案保留，原清單說明相容性原因，不把不相容誤報為檔案損壞。模型的 GGUF 主檔與 mmproj 完整性檢查仍保留。

另修正 W02：同一目錄放置多個 GGUF 時，舊配對規則把所有 `mmproj-模型名稱` 都當成無名編碼器，導致完整模型被判為不能使用。現在保留前綴後的型號，兼容 `模型名稱.mmproj` 形式；同分或僅有量化名稱的多個候選仍要求明確配對。下載後自動選取也統一路徑正規化，避免模型目錄經符號連結解析後無法選中。使用實際 Qwen3-VL／SmolVLM 目錄驗證此情境，並以 HTTP 測試完整下載、摘要驗證、掃描及自動選取流程。

## 比對範圍與驗證方式

- 重新對照 63 個 Swift 橋接動作與原有回呼，涵蓋開檔、列表、底片、調整、歷史、裁切、白平衡、校正、修復、AI、模型管理、單張／複選匯出、設定與 MCP。
- 共用配方正規化與投影沿用 1,957 組 Swift 參考案例；已修正的 F01～F13 納入回歸，不列為新發現。
- Go 測試使用隔離資料目錄，檢查配方、失效身分、設定保存、取消及失敗恢復。RAW 失敗分支以可控後端注入錯誤；不等同所有相機 RAW 的重新驗收。
- 真實 macOS Wails 與 Windows WebView2 執行移植及匯出 Smoke；修復取消 UI 使用僅存在於 `enginesmoke` 建置的可控工作，正式版不包含測試入口。
- 正式成品、平台、檢查數與限制以 Release 隨附的 `release-validation.json` 及 [還原紀錄](RESTORATION.md) 為準。Windows 實機為 Windows 10 x64／GTX 1060；不宣稱已測 Windows 11 或所有 GPU。

重跑方式（Go 指令於 `desktop` 目錄）：

```sh
go test -race ./internal/...
go vet ./internal/...
python3 ../engine/verification/desktop-smoke.py
python3 ../engine/verification/parity-smoke.py
python3 ../engine/verification/parity-smoke.py --second
```

Windows 使用相同 `enginesmoke` 建置及 JavaScript，設定 `FILMDEVELOP_SMOKE_PARITY=1` 或 `2`；第二輪另外透過 `FILMDEVELOP_SMOKE_MODEL_DIRECTORY` 指定實際 GGUF 模型。測試與正式封裝分開，Release 僅包含正式產品及公開驗證摘要。
