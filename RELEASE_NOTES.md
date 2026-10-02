# 1.26.1002 build 1208

本次將桌面主程序與共用功能改為 Go／Wails，macOS 影像與硬體計算由 Swift／C++ 處理，新增 Windows x64 Beta。相較上一個 Release `v1.26.0930-build-1745`：

- 兩平台共用底片、照片管理、調整、裁切、修復、AI 模型、MCP、更新與匯出流程。
- Windows 依實際能力偵測 RAW 解碼器與 Vulkan GPU；優先使用可用 GPU，失敗時回退 CPU。選項保存於設定，重啟時重新核對。
- 預覽先顯示列表縮圖，再漸進顯露套用參數的結果；共用解碼、遮罩與成品快取，改善切換照片／底片及連續調整。一般等待訊息放在照片下方，切換計算後端使用動畫對話框。
- 修正已編輯照片未還原參數；沿用舊 Swift 星級、分類、自訂底片、提示詞、遮罩、模型配對及介面偏好。增加移轉紀錄、資料庫匯出／匯入與重新定位，新版既有資料優先。
- 裁切選單增加有分隔線的「還原」，恢復原始大小與角度；計算過程保留目前畫面。
- 匯出預設名稱與 Swift 版一致，新增預設開啟的「寫入 EXIF」。JPEG、PNG、WebP、TIFF 可保留原始拍攝資訊，PNG／TIFF 支援 8／16 bit。
- 右鍵選單改為一般操作選單；對話框按鈕同列並依確認、取消、刪除分色；設定按鈕與左側底片列表更一致、緊湊。
- 自訂底片儲存後預設勾選，修正超大縮圖偏好，移除重複名稱提示及不存在的 MCP 設定檔列。
- 保留隱藏的 GR III・晴空暖橙配方，供舊照片及自訂底片還原，並同步 Swift、Go 與 Windows 色彩資料。

## 下載與升級

- Mac：Apple Silicon、macOS 14 以上，使用 `macos-arm64.dmg`。本次 DMG 與內含 App 已完成 Developer ID 簽章、Apple 公證、票證附加及 Gatekeeper 驗證。
- Windows：Windows 10／11 x64，使用 `windows-x64-setup.exe`；版本標示 Beta。需要 WebView2 與 VC++ x64 Runtime，安裝檔未簽 Authenticode。
- 首次從舊 Swift Mac 版升級，請手動下載混合版。舊更新器不使用新的套件名稱與識別碼。
- 資料移轉保留舊檔及收據，不覆寫新版已有修改。跨電腦資料包不含原始照片；只有舊雜湊而缺少來源路徑的紀錄需重新定位。

## 驗證與已知差異

已完成 Go race／vet、共用契約與資料檢查、Mac 原生和實際 Wails Smoke，以及 Windows 交叉編譯與封裝檢查。前輪 Windows 10／GTX 1060 實機涵蓋配方、編輯、匯出、資料移轉、GGUF 與 ONNX 修復；兩平台 CPU／GPU 共 1,216 組 Swift 影像參考比較通過。發布前補測本機 C++ CPU／GPU 各 289 組；Windows 10 實機完成 158 個 payload 檔案校驗、正式 GUI 啟動、10 項 WebView2 操作、3 項設定重開及 CPU／GPU 各 16 組比較。完整 NSIS 解壓校驗 159 檔（含清單本身），此次未在正式安裝位置重跑安裝／解除安裝。各輪測試與最終變更複測分開記錄，詳見[功能恢復紀錄](desktop/RESTORATION.md)。

44 份 RAW 樣本中，共用 LibRaw 成功解碼 38 份，其中 37 份通過嚴格跨平台數值比較。Nikon HE／HE*、GoPro GPR 仍有缺口。原生 RAW、主體／深度、降噪、景深與日期字形仍有平台差異；既有 Swift XCTest 的 10 個案例／20 個失敗斷言維持原基線。Windows 11、乾淨電腦缺少 Runtime 與其他 GPU 驅動仍需擴大驗證。
