# 更新紀錄

[繁體中文](CHANGELOG.md) · [English](CHANGELOG.en.md) · [日本語](CHANGELOG.ja.md) · [한국어](CHANGELOG.ko.md)

<!-- 由 scripts/release_notes.py 產生；請修改 history.json。 -->

## 1.26.1003 build 1300

相較版本：**1.26.1003 build 1109**。

- **修正**：修正外接磁碟 JPEG 匯出失敗，恢復單張與 MCP 顯影對話框、複選匯出張數與階段進度，確認取代後繼續保護來源照片。
- **修正**：第二輪修正 12 項 Swift 移植缺漏：底片重選、重設歷史、預覽重試、修復取消、直式裁切標籤、提示詞語言、PNG 8-bit 預設、自訂底片的儲存／複製／刪除／匯出，以及 RAW 切換失敗還原。
- **修正**：保留上一輪 13 項修正，包含 AI 七階段與取消、遮罩有效性、MCP 匯出設定、完整複選重設、照片副本定位與原生拖放。
- **修正 · Windows**：Windows 下載格式與本機模型選單隱藏 MLX，預設使用 GGUF；後端拒絕不支援平台的 MLX 下載，已下載檔案保留並顯示相容性說明。 同一目錄中的具名 mmproj 可正確配對；不猜測同分或不明確的組合。
- **改善**：減少狀態快照與復原歷史的重複配置，共用不可變影像字串與修復資料，清空淘汰紀錄參照；保持既有照片處理及介面版型。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

## 1.26.1003 build 1109

相較版本：**1.26.1003 build 1026**。

- **修正**：修正舊 FilmYourPhoto 首次移轉時長時間沒有提示：啟動即顯示等待對話框，列出設定、舊照片紀錄、目錄掃描與調整移轉階段；已知總量時顯示實際處理數與進度條，完成後自動解除等待。原始照片與舊版資料保留。
- **修正**：修正更新下載同時出現「取消」與「取消下載」，以及資訊視窗同時出現「取消」與「關閉」；共用對話框已有取消或關閉操作時，不再追加重複按鈕。
- **修正**：補齊共用對話框的四語標題、說明、按鈕與進度文字；「關閉視窗」與開關的 Off 分開處理，檔名、模型名稱及使用者輸入保留原文。
- **修正**：名稱輸入為空白時停用確認，Enter 也不會送出；對話框的鍵盤事件不再傳到背景裁切、修復與原圖比較，關閉後可恢復原控制項的焦點。
- **改善**：提示詞編輯改用原生模態對話框，避免焦點移到背景；介面狀態更新保留草稿，取消後回到原本的編輯入口。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1026...v1.26.1003-build-1109) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/desktop/RESTORATION.md)

## 1.26.1003 build 1026

相較版本：**1.26.1003 build 0924**。

- **新增**：目前照片需要另外安裝 Adobe DNG Converter 時，自動顯示確認對話框；確認後才用系統預設瀏覽器開啟 Adobe 官方下載頁，取代上一版僅提供照片下方入口的方式。
- **改善**：取消解碼器確認後保留畫面，同一張照片重試不反覆彈出；可從下方入口重新開啟。提示會等待其他對話框結束，忽略過期照片與無關錯誤，並提供四語說明。
- **修正**：更新下載視窗補上進度條，從 0% 起與百分比及容量同步，驗證安裝包時維持滿格；取消會清理暫存，舊下載事件不會影響新的對話框。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0924...v1.26.1003-build-1026) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1026/desktop/RESTORATION.md)

## 1.26.1003 build 0924

相較版本：**1.26.1003 build 0018**。

- **修正**：補上 Nikon HE／HE* NEF 與 GoPro GPR 的共同解碼流程：系統或 LibRaw 缺少解碼器時，使用已安裝的 Adobe DNG Converter 建立無損 RAW 快取，支援 Mac 與 Windows。
- **新增**：缺少補充解碼器時，在照片下方提供 Adobe 官方下載與重新偵測入口；使用者需自行完成原廠安裝。FilmDevelop 不內附 Adobe Converter，一般預覽不自動跳出安裝對話框。
- **修正**：GPR 加入照片匯入及兩平台 RAW 辨識；沒有可用內嵌縮圖時也能補充解碼，安裝後重新偵測可恢復列表縮圖。
- **改善**：補充解碼保留原始照片、調整識別與拍攝 EXIF；快取有內容驗證、容量上限、取消與結束清理。完整感光資料仍由共用 LibRaw 顯影，不以相機 JPEG 取代編輯來源。
- **改善**：補驗 Mac 47 張 RAW 的 141 次預覽／匯出、Windows 20 張的 60 次工作及預設系統模式 42 次工作；公開 EXIF、尺寸及像素差異紀錄。未知格式、JPEG XL／Enhanced DNG 與逐像素一致性仍有限制。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

## 1.26.1003 build 0018

相較版本：**1.26.1002 build 2330**。

- **修正**：更新完成視窗改為顯示本次新增、修正與改善，列出比較版本，並依介面語言顯示繁中、英文、日文或韓文。
- **修正**：跨版本升級會分版列出尚未看過的更新；其他對話框關閉後會再次顯示摘要，避免更新說明被略過。
- **改善 · Windows**：Windows 免安裝 ZIP 縮減 C++ 除錯資料，保留原有影像演算、查表、模型與 Microsoft Runtime。
- **新增**：新增逐版更新紀錄；README、程式摘要與 GitHub Release 使用同一份四語資料，並補列 build 2330 相較 build 1323 的差異。
- **改善**：完整發布流程先清空專案 dist，再依序建置 Mac 與 Windows；驗證版本紀錄與成品清單，避免混入舊版封裝。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

## 1.26.1002 build 2330

相較版本：**1.26.1002 build 1323**。

- **修正**：統一列表縮圖、編輯縮圖與完整預覽的顯示範圍，修正切換照片時過渡畫面突然放大的問題。
- **改善**：重用有容量上限的快取與 C++ 工作執行緒；Mac 軟體 RAW 編輯預覽採半尺寸解碼，完整預覽與匯出維持完整解碼。
- **改善**：共用乳劑晶體計算並對邊界重新計算，維持四樣本、三層與 FP32；指定量測的乳劑階段約快 30–35%，不代表整體預覽等幅加速。
- **新增 · Windows**：Windows 改為免安裝 ZIP，完整解壓即可執行，內附 12 個 Microsoft 原廠 VC++ x64 Runtime DLL；仍需要 WebView2。
- **新增 · Windows**：Windows 免安裝版可在程式內更新，檢查 ZIP 與逐檔 SHA-256，保留額外檔案並於啟動失敗時還原；舊 setup 版首次轉移需手動下載 ZIP。
- **修正**：修正 Swift Sendable 警告與建置系統相容性，並補驗 Windows CPU／Vulkan 影像與更新流程。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

## 1.26.1002 build 1323

相較版本：**1.26.0930 build 1745**。

- **新增**：桌面改為共用 Go／Wails，新增 Windows x64 Beta；Mac 繼續使用 Swift／C++ 影像引擎。
- **修正 · macOS**：舊 Swift Mac 版可直接更新；FilmYourPhoto 過渡包首次啟動即移轉安裝識別，後續使用標準 FilmDevelop 更新包。
- **新增**：沿用 Swift 的照片調整、星級、分類與自訂底片，新增移轉紀錄、資料庫匯出／匯入及重新定位；保留新版既有資料。
- **新增**：新增裁切還原及預設開啟的寫入 EXIF，匯出名稱與 Swift 一致；統一右鍵選單、按鈕分色、緊湊列表與自訂底片選取。
- **改善**：RAW 與計算加速預設為系統並保存選項；Windows 探測 Vulkan GPU，無法使用時回退 CPU。縮減重複封裝資源並檢查私人路徑。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.0930-build-1745...v1.26.1002-build-1323) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md)

[Swift · 更新紀錄 (繁體中文)](CHANGELOG.swift.md)
