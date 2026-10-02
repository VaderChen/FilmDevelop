# FilmDevelop — 照片沖洗

把照片調成喜歡的底片味道。選一款底片，再調整曝光、色彩與顆粒，就能匯出自己的作品。

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![照片沖洗 — FilmDevelop](demo.gif)

## 下載使用

[下載 Mac 版](https://github.com/VaderChen/FilmDevelop/releases/latest)，開啟 DMG 後，把「照片沖洗」拖進「應用程式」即可。

支援 **Apple Silicon Mac、macOS 14 以上**。介面有繁體中文、英文、日文與韓文，安裝檔已完成 Apple 公證。

## 特色

- **從底片到成品都能玩**：模擬感色層、乳劑顆粒、顯影藥水、印相紙與掃描，一路調整成像與質感。
- **經典風格，也能調出自己的味道**：Portra、Ektar、VISION3、Velvia、黑白與特殊底片，加上 GR III／GR IV 相機模擬；喜歡的設定可存成自訂底片。
- **每張照片都有自己的設定**：保留各張的調整、裁切與修復，隨時比較原圖；匯出從原檔計算，不覆蓋原始照片。
- **本機處理，AI 由你決定何時使用**：照片與調整留在 Mac，下載模型後可離線分析與修復，也可以完全手動調整。

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
| 匯出設定 | JPEG、PNG、WebP、TIFF；PNG／TIFF 可選 8／16 bit，支援尺寸、品質及 sRGB、Adobe RGB、Display P3。 |
| AI 與外部工具 | 手動啟動 AI 輔助分析與調整；進階使用者可開啟本機 MCP，連接支援的外部工具。 |

## 四步開始

1. 按「選取目錄」，挑一張照片。
2. 選喜歡的底片，或用「原片」開始調整。
3. 看著預覽微調；不滿意可以復原，也能隨時比較原圖。
4. 按「匯出照片」。多張照片可以一起匯出，各自保留自己的調整。

照片與調整紀錄留在本機。AI 模型首次使用需下載，準備好後可離線使用。

## 設定小提醒

加速設定請選 **「系統原生解析」與「系統原生加速」**。內建軟體解析與 Vulkan 也用於跨平台移植驗證。Windows x64 已能在本機建立安裝檔，完整 Windows 影像引擎及實機驗收仍待完成，尚未發布 Windows Release。

底片與相機風格是模擬效果，並非原廠預設或 LUT。更多操作提示可直接點選 App 內的功能標題查看。

<details>
<summary>想從原始碼執行？</summary>

`run.command` 現在建置並啟動 **Go／Wails 主程序 + Swift／C++ 影像引擎**。Go 管理 UI、照片列表、配方、紀錄、模型、MCP、更新及匯出流程；macOS 影像、AI 推論與修復由 Swift／C++ 執行。本機混合 App 使用 ad-hoc 簽章，與已公證的正式下載版分開驗收。功能恢復紀錄及兩平台安裝檔建置方式見 [Go 桌面說明](desktop/README.md)。

需要 Go 1.25 以上、Python 3.9 以上、完整 Xcode，以及 CMake、glslang、Vulkan headers／loader 和 MoltenVK；詳細相依項目見[建置說明](Vendor/PhotoCompute/README.md#建置與部署)。

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

</details>

## 授權

Copyright © 2026 VaderChen。可依[授權條款](LICENSE.md)免費使用、修改與分享；禁止商業販售及以本軟體提供收費服務，詳見[商業販售政策](COMMERCIAL-LICENSE.md)。照片與匯出作品不受本軟體授權限制，第三方元件依[各自授權](THIRD_PARTY_NOTICES.md)提供。
