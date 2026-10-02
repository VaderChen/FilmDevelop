# 第三方授權說明

FilmDevelop 的[原始碼公開・禁止商業販售授權](LICENSE.md) 適用於著作權人有權依該授權提供的內容，不撤回、限制或取代下列元件與資產的原始授權。以下為主要直接相依項目；子相依項目及個別檔案仍以隨附的 LICENSE、COPYING、NOTICE 與原始標頭為準。

| 元件 | 授權 | 本機位置／上游來源 |
| --- | --- | --- |
| llama.cpp | MIT | [隨附 LICENSE](aiTest2/ThirdParty/llama.cpp/LICENSE)；[上游](https://github.com/ggml-org/llama.cpp) |
| stable-diffusion.cpp | MIT | [隨附 LICENSE](aiTest/ThirdParty/stable-diffusion.cpp/LICENSE)；[上游](https://github.com/leejet/stable-diffusion.cpp) |
| MoltenVK | Apache-2.0 | macOS Vulkan 後端；建置時將完整授權加入 App 的 `PhotoCompute/Licenses/MoltenVK.txt` |
| nlohmann/json | MIT | [隨附 LICENSE](experiments/PhotoCoreCpp/third_party/nlohmann/LICENSE)；App 另附 `PhotoCompute/Licenses/nlohmann-json.txt` |
| LibRaw 0.22.2 | CDDL-1.0（上游另提供 LGPL-2.1 選項） | [上游固定版本](https://github.com/LibRaw/LibRaw/tree/0.22.2)；建置時附上 COPYRIGHT、LICENSE.CDDL、LICENSE.LGPL 及來源網址至 App 的 RAWLicenses |
| zlib 1.3.2 | zlib License | [固定來源](https://zlib.net/fossils/zlib-1.3.2.tar.gz)，RAW 後端靜態連結；授權與 SHA-256 隨 RAWLicenses／Windows Licenses/RAW 附上 |
| libjpeg-turbo 3.1.4.1 | IJG、BSD-3-Clause | [上游版本](https://github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.1.4.1)，支援有損 JPEG DNG；隨附 LICENSE.md、README.ijg。本軟體部分基於 Independent JPEG Group 的工作。 |
| X3F tools（LibRaw 0.22.2 隨附） | BSD-3-Clause | 來源為 LibRaw 的 `src/x3f/x3f_utils_patched.cpp`；完整授權另存 `X3F-LICENSE.txt` 隨原生 RAW 模組附上 |
| libwebp | BSD-3-Clause，另附專利授權 | [COPYING](Vendor/libwebp/macos/WebPLicenses/COPYING)、[PATENTS](Vendor/libwebp/macos/WebPLicenses/PATENTS)、[AUTHORS](Vendor/libwebp/macos/WebPLicenses/AUTHORS) |
| mlx-swift 0.31.6 | MIT | [上游 LICENSE](https://github.com/ml-explore/mlx-swift/blob/0.31.6/LICENSE) |
| mlx-swift-lm 3.31.4 | MIT | [上游 LICENSE](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/LICENSE) |
| swift-transformers 1.1.9 | Apache-2.0 | [上游 LICENSE](https://github.com/huggingface/swift-transformers/blob/1.1.9/LICENSE) |
| LaMa 修復模型（Core ML） | Apache-2.0 | [LaMa](https://github.com/advimman/lama)；[Core ML 轉換模型](https://huggingface.co/mlboydaisuke/LaMa-CoreML/tree/5ed76e3799ab4cad31381750d29880c267477e18)；[隨附授權](PhotoStyleApp/Models/LaMa-LICENSE.txt) |
| Depth Anything V2 Small（Core ML） | Apache-2.0 | [上游模型說明](https://github.com/DepthAnything/Depth-Anything-V2#license)；[Apple Core ML 模型頁](https://huggingface.co/apple/coreml-depth-anything-v2-small) |
| ONNX Runtime DirectML 1.24.4 | MIT，另附第三方通知 | Windows 本機視覺及修復推論；釘選 NuGet 套件與 SHA-256，授權封裝於 `Licenses/Neural` |
| Microsoft DirectML 1.15.4 | Microsoft 套件隨附授權 | Windows GPU 推論提供者；只隨附指定 x64 可散布元件與套件授權 |
| U²-Net 小型主體模型（ONNX） | Apache-2.0 | [U²-Net](https://github.com/xuebinqin/U-2-Net)；[rembg 轉換](https://github.com/danielgatis/rembg)；權重來源與 SHA-256 封裝於 `Licenses/Vision/NOTICE.txt` |
| Depth Anything V2 Small（ONNX） | Apache-2.0 | [固定轉換版本](https://huggingface.co/onnx-community/depth-anything-v2-small/tree/4472b7362082ad9968fee890ca0f1e5aca36b93d)；完整授權封裝於 `Licenses/Vision` |
| UltraFace（ONNX） | MIT | [上游模型](https://github.com/Linzaer/Ultra-Light-Fast-Generic-Face-Detector-1MB)；[固定 ONNX 權重](https://huggingface.co/onnxmodelzoo/version-RFB-320/tree/6fd293d22b523ec88959f104b8eef5395e3adfbc)；授權封裝於 `Licenses/Vision` |
| LaMa 修復模型（ONNX） | Apache-2.0 | [LaMa](https://github.com/advimman/lama)；[固定轉換版本](https://huggingface.co/Carve/LaMa-ONNX/tree/c3c0c9e468934d62e79c329e35d82dd09ff8c444)；Windows 首次修復時下載，照片不離開本機 |
| stb_image | MIT（上游另提供 public domain 選項） | llama.cpp 視覺輸入解碼；授權封裝於 `Licenses/LLM/stb-image.txt` |

Swift 套件版本取自 [MLXRuntime/Package.swift](MLXRuntime/Package.swift)，授權已核對本機 checkout；子模組以 Git 記錄的版本及隨附授權為準。

## Oklab 色彩轉換

相機模擬核心的線性 sRGB／Oklab 矩陣轉換改寫自 Björn Ottosson 的[公開實作](https://bottosson.github.io/posts/oklab/)。作者將該程式碼提供為 public domain，亦提供 MIT 授權選項；此處採 public domain 版本，並保留來源註記。GR 配方、明度曲線、色相權重及色調參數由本專案設計，不是 Ricoh 原廠 LUT、量測資料或原廠背書。

## 模型與影像

版本庫包含 `PhotoStyleApp/Models/DepthAnythingV2SmallF16P6.mlpackage`；對應 `.mlmodelc` 為本機編譯產物，不納入版本控制。其 metadata 標示作者為 Lihe Yang 等人、授權為 Apache 2，精度為 Float16／6-bit palettized；它們依模型原始授權提供。Small 的授權不能推廣到其他尺寸或其他模型。轉換來源、修改及散布通知仍應依實際模型版本保留。

使用者另外下載的 AI 權重依各模型授權使用，請保留模型隨附的授權與來源。使用者照片及其匯出成果的權利不因本程式的授權而改變。底片品牌名稱只用於辨識模擬風格，不代表原廠背書或提供商標授權。

## 散布時的授權文件

散布原始碼時，保留本專案 LICENSE.md，以及第三方元件原有的著作權、授權、NOTICE 與專利聲明；子模組內的其他第三方內容也需保留自己的聲明。

散布 App 或執行檔時，需隨附實際包含元件所要求的完整授權與通知。本表是索引，不能取代那些文件。現有 WebP 建置流程會將 `WebPLicenses` 加入 App，MLX 建置流程會收集 checkout 的 LICENSE／COPYING／NOTICE。其他元件與模型需依實際發佈內容補齊；每次封裝的檔案清單與雜湊檢查結果另存於對應的建置報告。

修復筆刷使用固定版本的 LaMa Core ML 模型，首次使用時下載約 217 MB，並以 SHA-256 核對三個模型檔案。模型在本機執行；不傳送照片。此模型不是 Apple 隨系統附送的「清除」功能。

Windows 使用約 208 MB 的 LaMa ONNX 模型，Go 負責下載、取消及 SHA-256 驗證，C++／ONNX Runtime 負責執行。Microsoft Visual C++ x64 執行環境由安裝前置步驟檢查；缺少時從 Microsoft 下載原廠安裝器並核對雜湊及簽章，不從本機抽取系統 DLL 重新封裝。
