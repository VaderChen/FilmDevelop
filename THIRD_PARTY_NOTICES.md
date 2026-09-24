# 第三方授權說明

FilmDevelop 的[原始碼公開・禁止商業販售授權](LICENSE.md) 適用於著作權人有權依該授權提供的內容，不撤回、限制或取代下列元件與資產的原始授權。以下為主要直接相依項目；子相依項目及個別檔案仍以隨附的 LICENSE、COPYING、NOTICE 與原始標頭為準。

| 元件 | 授權 | 本機位置／上游來源 |
| --- | --- | --- |
| llama.cpp | MIT | [隨附 LICENSE](aiTest2/ThirdParty/llama.cpp/LICENSE)；[上游](https://github.com/ggml-org/llama.cpp) |
| stable-diffusion.cpp | MIT | [隨附 LICENSE](aiTest/ThirdParty/stable-diffusion.cpp/LICENSE)；[上游](https://github.com/leejet/stable-diffusion.cpp) |
| libwebp | BSD-3-Clause，另附專利授權 | [COPYING](Vendor/libwebp/macos/WebPLicenses/COPYING)、[PATENTS](Vendor/libwebp/macos/WebPLicenses/PATENTS)、[AUTHORS](Vendor/libwebp/macos/WebPLicenses/AUTHORS) |
| mlx-swift 0.31.6 | MIT | [上游 LICENSE](https://github.com/ml-explore/mlx-swift/blob/0.31.6/LICENSE) |
| mlx-swift-lm 3.31.4 | MIT | [上游 LICENSE](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/LICENSE) |
| swift-transformers 1.1.9 | Apache-2.0 | [上游 LICENSE](https://github.com/huggingface/swift-transformers/blob/1.1.9/LICENSE) |
| LaMa 修復模型（Core ML） | Apache-2.0 | [LaMa](https://github.com/advimman/lama)；[Core ML 轉換模型](https://huggingface.co/mlboydaisuke/LaMa-CoreML/tree/5ed76e3799ab4cad31381750d29880c267477e18)；[隨附授權](PhotoStyleApp/Models/LaMa-LICENSE.txt) |
| Depth Anything V2 Small（Core ML） | Apache-2.0 | [上游模型說明](https://github.com/DepthAnything/Depth-Anything-V2#license)；[Apple Core ML 模型頁](https://huggingface.co/apple/coreml-depth-anything-v2-small) |

Swift 套件版本取自 [MLXRuntime/Package.swift](MLXRuntime/Package.swift)，授權已核對本機 checkout；子模組以 Git 記錄的版本及隨附授權為準。

## Oklab 色彩轉換

相機模擬核心的線性 sRGB／Oklab 矩陣轉換改寫自 Björn Ottosson 的[公開實作](https://bottosson.github.io/posts/oklab/)。作者將該程式碼提供為 public domain，亦提供 MIT 授權選項；此處採 public domain 版本，並保留來源註記。GR 配方、明度曲線、色相權重及色調參數由本專案設計，不是 Ricoh 原廠 LUT、量測資料或原廠背書。

## 模型與影像

版本庫包含 `PhotoStyleApp/Models/DepthAnythingV2SmallF16P6.mlpackage`；對應 `.mlmodelc` 為本機編譯產物，不納入版本控制。其 metadata 標示作者為 Lihe Yang 等人、授權為 Apache 2，精度為 Float16／6-bit palettized；它們依模型原始授權提供。Small 的授權不能推廣到其他尺寸或其他模型。轉換來源、修改及散布通知仍應依實際模型版本保留。

使用者另外下載的 AI 權重依各模型授權使用，請保留模型隨附的授權與來源。使用者照片及其匯出成果的權利不因本程式的授權而改變。底片品牌名稱只用於辨識模擬風格，不代表原廠背書或提供商標授權。

## 散布時的授權文件

散布原始碼時，保留本專案 LICENSE.md，以及第三方元件原有的著作權、授權、NOTICE 與專利聲明；子模組內的其他第三方內容也需保留自己的聲明。

散布 App 或執行檔時，需隨附實際包含元件所要求的完整授權與通知。本表是索引，不能取代那些文件。現有 WebP 建置流程會將 `WebPLicenses` 加入 App，MLX 建置流程會收集 checkout 的 LICENSE／COPYING／NOTICE。其他元件與模型需依實際發佈內容補齊；本次設定版本庫授權，未重新製作或稽核發佈套件。

修復筆刷使用固定版本的 LaMa Core ML 模型，首次使用時下載約 217 MB，並以 SHA-256 核對三個模型檔案。模型在本機執行；不傳送照片。此模型不是 Apple 隨系統附送的「清除」功能。
