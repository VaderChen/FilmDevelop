# FilmDevelop — 照片沖洗

把照片調成喜歡的底片味道。選一款底片，再調整曝光、色彩與顆粒，就能匯出自己的作品。

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![照片沖洗 — FilmDevelop](demo.gif)

## 下載使用

[下載 Mac 與 Windows 版](https://github.com/VaderChen/FilmDevelop/releases/latest)。目前版本：**1.26.1003 build 0018**，Windows 標示 **Beta**。

| 平台 | 安裝方式與需求 |
| --- | --- |
| macOS | Apple Silicon、macOS 14 以上。開啟 `macos-arm64.dmg`，將 FilmDevelop 拖進「應用程式」。本次 DMG 及內含 App 已完成 Developer ID 簽章、Apple 公證與票證附加。 |
| Windows Beta | Windows 10／11 x64，完整解壓 `windows-x64-portable.zip` 後執行 `FilmDevelop.exe`。內附 VC++ x64 Runtime，仍需 WebView2；主程式未簽署 Authenticode。 |

舊 Windows setup 版首次改用 ZIP 需手動下載並解壓至新資料夾；設定與照片調整會沿用，之後可在免安裝版內更新。ZIP 不保證消除 Windows 來源提示。

兩個平台共用繁體中文、英文、日文與韓文介面。舊 Swift Mac 版可使用「檢查更新」直接升級；FilmYourPhoto 過渡包會在第一次開啟時，將原安裝位置轉為標準 FilmDevelop 身分，不需第二次下載。完成後，後續更新只使用 FilmDevelop；過渡期仍保留舊 Swift 與先前相容包的升級入口。安裝後會沿用可辨識的照片調整、星級、分類與自訂底片，既有新版資料優先。換電腦可在設定中「匯出資料庫／匯入並重新定位」；資料包不含原始照片，舊紀錄缺少原路徑時需重新定位。

<!-- release-summary:start -->
## 本次更新

相較版本：**1.26.1002 build 2330**。

- **修正**：更新完成視窗改為顯示本次新增、修正與改善，列出比較版本，並依介面語言顯示繁中、英文、日文或韓文。
- **修正**：跨版本升級會分版列出尚未看過的更新；其他對話框關閉後會再次顯示摘要，避免更新說明被略過。
- **改善 · Windows**：Windows 免安裝 ZIP 縮減 C++ 除錯資料，保留原有影像演算、查表、模型與 Microsoft Runtime。
- **新增**：新增逐版更新紀錄；README、程式摘要與 GitHub Release 使用同一份四語資料，並補列 build 2330 相較 build 1323 的差異。
- **改善**：完整發布流程先清空專案 dist，再依序建置 Mac 與 Windows；驗證版本紀錄與成品清單，避免混入舊版封裝。

[完整更新紀錄](CHANGELOG.md)
<!-- release-summary:end -->

## 特色

- **從底片到成品都能玩**：模擬感色層、乳劑顆粒、顯影藥水、印相紙與掃描，一路調整成像與質感。
- **經典風格，也能調出自己的味道**：Portra、Ektar、VISION3、Velvia、黑白與特殊底片，加上 GR III／GR IV 相機模擬；喜歡的設定可存成自訂底片。
- **每張照片都有自己的設定**：保留各張的調整、裁切與修復，隨時比較原圖；匯出從原檔計算，不覆蓋原始照片。
- **本機處理，AI 由你決定何時使用**：照片與調整留在電腦，下載模型後可離線分析與修復，也可以完全手動調整。

## 功能一覽

| 功能 | 可以怎麼用 |
| --- | --- |
| 底片收藏與自訂 | 收藏、排序、調整風格強度；自訂底片可改名、複製、匯入與匯出。 |
| 顯影與底片質感 | 調整顯影時間、溫度、攪拌、反差、顆粒、柔光與紅暈；進一步玩感色層、乳劑、互易律與銀鹽密度。 |
| 掃描與印相 | 選擇掃描器模擬、底片或相片掃描，搭配亮面、霧面、暖調纖維紙，調整印相光源與冷暖。 |
| RAW 與明暗色彩 | 保留原片曝光與白平衡，支援相容 RAW 的鏡頭修正；可用白平衡滴管、分區曝光、反差、鮮豔度、飽和度與 HDR。 |
| 人像與細節 | 磨皮、美白、膚色冷暖、背景與鏡頭模糊，搭配去雜訊和暗角補償。 |
| 即時預覽 | 滑鼠停在底片上先試看，放大檢查細節、比較原圖，也能查看 RGB 直方圖。 |
| 構圖與修復 | 自由或固定比例裁切、旋轉、AI 修復筆刷、外框與日期印字；支援復原與重做。 |
| 照片整理 | 縮圖複選、星級、自訂分類、排序與篩選，查看 EXIF，快速開啟最近使用的目錄。 |
| 複製與批次處理 | 複製照片並保留調整，複製參數套用到多張照片，也能批次恢復原片與匯出。 |
| 匯出設定 | JPEG、PNG、WebP、TIFF；PNG／TIFF 可選 8／16 bit，支援尺寸、品質及 sRGB、Adobe RGB、Display P3；「寫入 EXIF」預設開啟，保留原始拍攝資訊。 |
| AI 與外部工具 | 手動啟動 AI 輔助分析與調整；進階使用者可開啟本機 MCP，連接支援的外部工具。 |

## 四步開始

1. 按「選取目錄」，挑一張照片。
2. 選喜歡的底片，或用「原片」開始調整。
3. 看著預覽微調；不滿意可以復原，也能隨時比較原圖。
4. 按「匯出照片」。多張照片可以一起匯出，各自保留自己的調整。

照片與調整紀錄留在本機。AI 模型首次使用需下載，準備好後可離線使用。

## 設定小提醒

RAW 與計算加速預設使用 **系統**，選項會保存並在啟動時重新偵測。Mac 使用 Apple 原生加速；Windows 優先採用通過實際探測的 Vulkan GPU，無法使用時回退 CPU。系統 RAW 解碼失敗時，使用內建 LibRaw 備援。

已測試 44 份、17 品牌、31 種機型的 RAW；共用 LibRaw 成功解碼 38 份，其中 37 份通過嚴格跨平台數值比對。Nikon HE／HE* 與 GoPro GPR 仍有缺口；原生 RAW、主體、景深、降噪與日期字形也可能因平台不同而有差異。詳細驗證範圍見[功能恢復紀錄](desktop/RESTORATION.md)。

底片與相機風格是模擬效果，並非原廠預設或 LUT。更多操作提示可直接點選 App 內的功能標題查看。

<details>
<summary>想從原始碼執行？</summary>

`run.command` 建置並啟動 **Go／Wails 主程序 + Swift／C++ 影像引擎**。Go 管理 UI、照片、配方、設定、模型、MCP、更新及匯出；macOS 硬體計算由 Swift／C++ 負責，Windows 由 C++ 負責。一般本機建置使用 ad-hoc 簽章；正式簽章、公證與 Windows 免安裝 ZIP 建置方式見 [Go 桌面說明](desktop/README.md)。

需要 Go 1.25 以上、Python 3.9 以上、完整 Xcode，以及 CMake、glslang、Vulkan headers／loader 和 MoltenVK；詳細相依項目見[建置說明](Vendor/PhotoCompute/README.md#建置與部署)。

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

</details>

## 授權

Copyright © 2026 VaderChen。可依[授權條款](LICENSE.md)免費使用、修改與分享；禁止商業販售及以本軟體提供收費服務，詳見[商業販售政策](COMMERCIAL-LICENSE.md)。照片與匯出作品不受本軟體授權限制，第三方元件依[各自授權](THIRD_PARTY_NOTICES.md)提供。
