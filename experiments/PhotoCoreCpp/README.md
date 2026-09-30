# C++ 影像處理移植測試

後續 App 整合已新增共用後端中介層與 C ABI，設定可實際切換原生／Vulkan；RAW 解析也統一經由路由器。這裡的 CLI 與歷史量測仍保留為獨立驗證，App 的相鄰 Vulkan 階段採用 GPU 常駐計算圖，詳見 [App 後端中介層](../../Vendor/PhotoCompute/README.md)。

此目錄是獨立的 C++17 實驗專案。預設核心採 CPU 純數值運算，可在 macOS、Windows x64 與 Linux 建置；預設建置沒有連結 App、Swift、Core Image、Metal、LibRaw 或其他影像函式庫。另可選配獨立 Vulkan Compute 後端，目前已在 macOS／MoltenVK 驗證，尚未建置 Windows Vulkan 版本。

目前已有曝光基礎核心及 **CPU 底片／顯影／掃描串接流程；CPU CLI 保持獨立，Vulkan 已透過中介層接入 App**。三模組最終成品的 478 組比較全部通過，最大 ΔE00 為 1.497445；詳細範圍與重跑方式見 [底片 CPU 驗證](FILM_CPU.md)。這不等於完整 App 配方已移植。依目前任務要求暫緩 Windows x64 建置，本次只驗證 macOS 原生 C++；macOS Swift 工具僅用於產生參考資料。

Swift 原版（Core Image／Metal）與 Vulkan 的兩個複雜階段實測，見 [Swift／Vulkan 效能比較](SWIFT_VULKAN_PERFORMANCE.md)。目前 2400 萬像素顯影與光譜階段的 Vulkan 耗時分別為 Swift 的 2.29 與 6.38 倍。

## 驗收標準：完整流程的最終成品 ΔE00 < 2

**不能用單一函式、曝光比對、平均 ΔE，或比較器本身的 Smoke 測試宣告移植成功。** 同一份輸入、同一份完整參數，必須分別執行 Swift 與 C++ 的完整影像處理流程，再比較最終成品。

- 量測採 CIEDE2000（ΔE00，kL = kC = kH = 1），每張照片的**所有像素最大值必須嚴格小於 2**。同時記錄平均、P95、P99、超標像素數及最大誤差位置。
- 比較契約：相同固定解碼輸入 → 完整處理 → PNG16／sRGB 成品 → 重新解碼成線性 sRGB → D65 Lab → ΔE00。RAW 的線性影像與原生顯影分開提供，保留原片及低強度底片的來源分支。
- 照片尺寸及方向必須一致；禁止在比較時縮圖、對齊、平滑或裁色來降低誤差。PFM 頂列為座標原點，檔案依規格底列先存。
- 預設底片的顆粒等效果不為通過門檻而關閉。RAW 解碼器差異先排除：兩端使用相同已解碼像素，這是影像演算法驗收，不是解碼器移植驗收。
- 缺少配方、未實作步驟、處理失敗、缺少成品、資料雜湊不符或任一像素 ΔE00 ≥ 2，整批驗收均不通過。每次都用新產物目錄，不能沿用舊結果。

### 建立完整流程參考與執行驗收

```sh
# 由目前 Swift 原始碼重新建置獨立參考工具，無須修改或啟動 App。
bash experiments/PhotoCoreCpp/tools/build_pipeline_fixture.sh

# 每張輸入涵蓋 37 種風格的預設／複合調整，以及 23 種底片低強度分支，共 97 組。
# 最長邊是固定輸入的尺寸；比較時不再縮放。可提高到 512 或實際使用尺寸重跑。
build/photocore-cpp/pipeline-fixture build/photocore-cpp/pipeline-fixtures 192 images/test.jpg

python3 experiments/PhotoCoreCpp/tools/verify_pipeline.py \
  build/photocore-cpp/pipeline-fixtures/manifest.json \
  --renderer build/photocore-cpp/photo_core_test \
  --comparator build/photocore-cpp/photo_core_compare \
  --report build/photocore-cpp/pipeline-report.json
```

**目前最後一個指令應以失敗結束**：`photo_core_test` 尚未實作 `--recipe` 完整流程，不能以其既有三階段處理代替。日後完整 C++ renderer 必須接受 `--input input.pfm --recipe recipe.json --output final.pfm`，RAW 案例另傳 `--camera-original original.pfm`；`final.pfm` 是完成配方與上述輸出色彩／量化邊界後的成品。未支援的參數必須明確失敗。

參考工具呼叫現有 `PhotoStyleProcessor.apply(isPreview: false)`，包含風格強度混合、顯影、底片、色調、掃描及成品匯出；不是手工拼接幾個函式。測試副本只加入步驟記錄與失敗旗標，避免產品入口的錯誤回退原圖被當成成功；產品來源不變。`manifest.json` 保存完整配方、執行步驟、輸入／成品雜湊及 Swift 來源版本。每次重新產生時先移除舊 manifest，失敗時不會留下可冒用的舊驗收清單。

目前矩陣尚不涵蓋 AI 遮罩／景深、修復、裁切／裝飾及所有參數極值，也未完成 Windows 實機比對。測試矩陣通過後仍須補足欲支援功能，不能宣稱所有選項皆已移植。

`photo_core_compare` 可單獨比較兩張最終線性 sRGB PFM，回傳 JSON。它只是量測工具，無法單靠兩張圖證明上游已執行哪些步驟；正式驗收必須透過完整流程 runner。

```sh
build/photocore-cpp/photo_core_compare swift-final.pfm cpp-final.pfm
```

### 目前驗收狀態（2026-09-30）

- 真實 JPEG 與 Canon CR2 共產生 **194 組完整 Swift 參考成品**，最長邊 192 像素，保留對應 PNG16、PFM 與參數。
- **完整 C++ 驗收尚未通過：0／194 組；可量測的 C++ 完整成品為 0 組。** 原因是完整配方入口與多個處理階段尚未移植，不是已測得 ΔE 超過 2；目前沒有可宣告的端到端色差上限。
- 比較器通過 [34 組 CIEDE2000 公開參考值](https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/)，資料來源另記於 `verification/data/README.md`。
- 九項 CTest／Smoke 通過，包括單點超標而平均未超標、尺寸不符、HDR 中間值、NaN、缺件、資料遭修改、空案例集合及未支援配方等拒絕路徑。這些結果僅證明工具正常。

## 本階段範圍

| 功能 | 現有依據 | 進度 |
| --- | --- | --- |
| 曝光滑桿與 EV 轉換 | `PhotoExposureScale.swift` | 已移植、Swift 數值比對 |
| 全域及分區曝光 | `PhotoExposureProcessor.swift`、`PhotoExposureProtection.swift` | 已移植，保留斜率約束、softplus 與預乘 alpha |
| 高光保護 | `PhotoExposureProtection.swift` | 已移植，亮度／峰值兩種保護 |
| RAW 顯示高光映射 | `PhotoRAWDynamicRangeProcessor.swift` | 已移植、Core Image 像素比對 |
| 3×6 根多項式色彩校準 | `PhotoColorCalibration.swift` | 已移植，略過負分量、保留 alpha |
| 線性 sRGB → D65 Lab | `PhotoExposureColor.swift` | 已移植前向轉換，供差異分析 |
| 局部反差／明暗 | `PhotoLocalToneProcessor.swift` | 尚待移植 guided filter、取樣及重建 |
| 色溫／色偏 | `PhotoToneProcessor.swift` | 尚待定義與 `CITemperatureAndTint` 的相容契約 |
| 底片模型、顯影、掃描 | `PhotoFilm*Processor.swift`、光譜資料 | CPU 三模組串接已移植；478 組最終成品 ΔE00 最大值 < 2，見 `FILM_CPU.md` |
| 裁切／旋轉、修復、顆粒、模糊、HDR | 各自處理模組 | 尚待移植 |
| RAW／JPEG／PNG 解碼、ICC | 解碼／色彩管理層 | 不包含於這一批核心；透過 PFM 交換已解碼像素 |

未以 RGB gain 假裝完成原本的色溫，也未以一般 S 曲線替代底片光譜運算。後續仍需移植局部反差、色溫、乳劑與其他 App 處理階段，整合後必須重新驗收完整 App 最終成品，不能累加單一模組的通過結果。

## 影像與參數契約

- 核心使用 extended-linear sRGB、Float32 RGBA、預乘 alpha；不截斷負色分量及大於 1 的高光。
- 影像容器以左上角為原點。PFM 採規格的底列先存，讀寫時轉換行順序；支援大小端與 scale。
- PFM 不攜帶 ICC，也沒有 alpha，本工具約定其像素必須是線性 sRGB。RGBA 透明度由記憶體測試涵蓋。PFM 輸出拒絕非不透明像素及非有限數值。
- 核心不套用 RAW 相機基準曝光。該補償應由解碼層套用一次；不可在曝光滑桿重複添加。
- 區域參數依亮部／中調／暗部排列，是絕對 EV；global EV 是分區殘差的參考錨點。各值限制於 ±16 EV，strength 限制於 0…1。維持既有 Swift 全零區域直接略過的契約。
- 預覽 PPM 會將線性值轉成 sRGB，再截至 8-bit SDR，不能用來判定 HDR 精度。比較請用 PFM 或記憶體像素。
- 色彩校準檔是純文字 18 個數值，依 3 列 × 6 欄排列，各列依序對應 R、G、B、sqrt(RG)、sqrt(GB)、sqrt(RB)。係數須有限且介於 -16…16。
- CPU 核心尚未使用多執行緒或 SIMD；Vulkan 另有 GPU 常駐實作，詳見 `VULKAN_FILM.md`。底片流程已減少影像複製並重用 CPU 緩衝區；傳入 lvalue 時保留原始影像，傳入暫存值或 `std::move` 時移轉所有權並重用其空間，詳見 `PERFORMANCE.md`。

## 建置與操作

在儲存庫根目錄執行（需 CMake 3.20+ 與 C++17 編譯器）：

```sh
cmake -S experiments/PhotoCoreCpp -B build/photocore-cpp -DCMAKE_BUILD_TYPE=Release
cmake --build build/photocore-cpp --config Release
ctest --test-dir build/photocore-cpp -C Release --output-on-failure

build/photocore-cpp/photo_core_test --generate --ev 0.7 --protect-peak --raw-map \
  --output build/photocore-cpp/result.pfm --preview build/photocore-cpp/view.ppm

build/photocore-cpp/photo_core_test --input build/photocore-cpp/result.pfm \
  --zones 0.3 0.1 -0.2 --output build/photocore-cpp/adjusted.pfm
```

`--ev` 同時設定三區 EV 與 global 錨點；`--zones` 覆寫三區，參數依命令列順序生效。執行順序固定為輸入色彩校準 → 曝光 → 選用 RAW 顯示映射。執行檔回傳 0 代表成功，其餘代表失敗；輸入與輸出不可指向相同路徑。

下列 Windows 指令保留供後續使用；本次未執行，也不代表新三模組已通過 Windows 驗證。

Windows x64（Visual Studio 2022，安裝「使用 C++ 的桌面開發」）：

```powershell
cmake -S experiments/PhotoCoreCpp -B build/photocore-cpp-windows -G "Visual Studio 17 2022" -A x64
cmake --build build/photocore-cpp-windows --config Release
ctest --test-dir build/photocore-cpp-windows -C Release --output-on-failure
.\build\photocore-cpp-windows\Release\photo_core_test.exe --generate --ev 0.7 --output result.pfm --preview view.ppm
```

跨編譯器產物比較時不要開啟 fast-math。MSVC 使用 `/fp:precise`，Clang／GCC 使用 `-fno-fast-math -ffp-contract=off`。CLI 在 Windows 以 Unicode 入口接收參數，核心檔案路徑統一使用 UTF-8。

macOS／Linux 的 Windows x64 交叉編譯（需已安裝 MinGW-w64）：

```sh
cmake -S experiments/PhotoCoreCpp -B build/photocore-cpp-win64 -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=cmake/windows-x64-mingw.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build/photocore-cpp-win64
```

Windows 測試包內有 `.exe`、Swift 參考值與 `windows-smoke.ps1`。解壓後執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-smoke.ps1 -Build . -Reference .\swift-reference.txt
```

這只在該次程序執行腳本，沒有修改全機執行原則。Windows 版靜態連結 MinGW C++ 執行期，仍依賴 Windows 系統的 UCRT／Kernel32。

## 現有實作比對

macOS 先有目前專案 Debug 建置的 `PhotoStyleShared.o`，再執行：

```sh
bash experiments/PhotoCoreCpp/tools/verify_against_swift.sh
```

工具直接編譯目前的 `PhotoExposureProtection.swift`、`PhotoExposureColor.swift`、`PhotoExposureScale.swift`，並呼叫現有 Core Image 模組，產生 10,799 筆參考資料；C++ 測試逐筆比較。純 CPU double 公式容差為 1e-10（滑桿 1e-12），Float32 曝光 2e-6，Core Image 像素 3e-5，均以 `abs(error) / max(1, abs(reference))` 判定。必須先更新 Debug 模組，不能使用過期的 `.o` 作為新版公式的參考。

單一曝光階段的真實照片診斷（**不是完整流程驗收**；解碼僅在 macOS fixture 工具執行）：

```sh
xcrun swiftc -parse-as-library -I build/DerivedData/Build/Products/Debug \
  experiments/PhotoCoreCpp/tools/image_fixture.swift \
  build/DerivedData/Build/Products/Debug/PhotoStyleShared.o -o build/photocore-cpp/image-fixture
build/photocore-cpp/image-fixture images/test.jpg \
  build/photocore-cpp/photo.pfm build/photocore-cpp/photo-expected.pfm
python3 experiments/PhotoCoreCpp/tools/image_smoke.py build/photocore-cpp/photo_core_test \
  --input build/photocore-cpp/photo.pfm --reference build/photocore-cpp/photo-expected.pfm
```

記憶體檢查：

```sh
cmake -S experiments/PhotoCoreCpp -B build/photocore-cpp-sanitize \
  -DCMAKE_BUILD_TYPE=Debug -DPHOTOCORE_SANITIZE=ON
cmake --build build/photocore-cpp-sanitize
ctest --test-dir build/photocore-cpp-sanitize --output-on-failure
```

## 既有子系統結果（2026-09-30，不代表端到端達標）

- macOS AppleClang Release、原有三項 CTest 通過；加入完整成品比較器後為六項。
- 10,799 筆 Swift／Core Image 比對通過，搭配數學不變量共 70,341 次檢查。
- 實際 JPEG 的 768×511 像素、1,177,344 色彩分量曝光比對通過，最大正規化誤差約 1.20e-7。
- AddressSanitizer／UndefinedBehaviorSanitizer 及命令列檔案流程通過。
- MinGW-w64 產出 PE32+ x86-64 Windows 執行檔；尚未在 Windows 主機執行，不宣稱已通過 Windows 執行或 MSVC 驗證。
- 原始照片、App 專案及目前產品處理入口均未在本實驗中修改。建置產物與記錄位於 `build/photocore-cpp*`，不是正式 Release。

效率與記憶體量測、最佳化方式及重跑命令見 [CPU 效能驗證](PERFORMANCE.md)。

獨立的 [Vulkan Compute Smoke](VULKAN_SMOKE.md) 已在 Apple M4 Pro 通過：將光譜 `unmix()` 放到 GPU FP32，與 CPU 其他步驟串接，10 組最終成品相對 Swift 最大 ΔE00 為 0.955630。此為預設關閉的實驗目標，不代表全 GPU 移植或整體效率驗證。

[Vulkan 反算效能量測](VULKAN_PERFORMANCE.md) 保留第一階段的微核心結果；後續已完成 [Vulkan 三模組移植與計算盤點](VULKAN_FILM.md)，讓中間影像常駐 GPU，涵蓋曝光、顯影反應擴散、藥水、光譜、底片風格、掃描與成品量化。478 組 Swift 最終成品比較全部通過，最大 ΔE00 為 1.49744469042。仍為獨立實驗，尚未整合 App。
