# 更新紀錄

[繁體中文](CHANGELOG.md) · [English](CHANGELOG.en.md) · [日本語](CHANGELOG.ja.md) · [한국어](CHANGELOG.ko.md)

<!-- 由 scripts/release_notes.py 產生；請修改 history.json。 -->

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
