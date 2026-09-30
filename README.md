# FilmDevelop — 照片沖洗

把照片調成喜歡的底片味道。選一款底片，再調整曝光、色彩與顆粒，就能匯出自己的作品。

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![照片沖洗 — FilmDevelop](demo.gif)

## 下載使用

[下載 Mac 版](https://github.com/VaderChen/FilmDevelop/releases/latest)，開啟 DMG 後，把「照片沖洗」拖進「應用程式」即可。

支援 **Apple Silicon Mac、macOS 14 以上**。介面有繁體中文、英文、日文與韓文，安裝檔已完成 Apple 公證。

## 可以做什麼？

- **挑選底片風格**：彩色、黑白、電影底片與 GR 相機模擬，也能儲存自己的調整。
- **慢慢調出喜歡的感覺**：從曝光、白平衡、反差到顆粒、顯影與掃描，都能自己微調。
- **整理與批次處理**：用星級和分類整理照片，複製調整參數後，一次套用到多張照片。
- **修整畫面**：裁切、旋轉、修復不想要的物件，也能加上外框與日期。
- **讓 AI 幫忙**：下載模型後，可在本機分析照片、協助調整，照片不會上傳。
- **匯出成品**：支援 JPEG、PNG、WebP、TIFF，可選尺寸與色彩空間，原始照片不會被覆蓋。

## 四步開始

1. 按「選取目錄」，挑一張照片。
2. 選喜歡的底片，或用「原片」開始調整。
3. 看著預覽微調；不滿意可以復原，也能隨時比較原圖。
4. 按「匯出照片」。多張照片可以一起匯出，各自保留自己的調整。

照片與調整紀錄留在本機。AI 模型首次使用需下載，準備好後可離線使用。

## 設定小提醒

加速設定請選 **「系統原生解析」與「系統原生加速」**。內建軟體解析與 Vulkan 是為 Windows 平台做準備，目前供測試使用，尚未提供 Windows 安裝版。

底片與相機風格是模擬效果，並非原廠預設或 LUT。更多操作提示可直接點選 App 內的功能標題查看。

<details>
<summary>想從原始碼執行？</summary>

需要完整 Xcode，以及 CMake、glslang、Vulkan headers／loader 和 MoltenVK；詳細相依項目見[建置說明](Vendor/PhotoCompute/README.md#建置與部署)。

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

</details>

## 授權

Copyright © 2026 VaderChen。可依[授權條款](LICENSE.md)免費使用、修改與分享；禁止商業販售及以本軟體提供收費服務，詳見[商業販售政策](COMMERCIAL-LICENSE.md)。照片與匯出作品不受本軟體授權限制，第三方元件依[各自授權](THIRD_PARTY_NOTICES.md)提供。
