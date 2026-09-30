# CPU 底片、顯影、掃描驗證

此實驗將現有 Swift 底片相關模組移植為獨立 C++17 CPU 程式 `photo_core_film`，不整合 App。依目前要求，Windows x64 建置暫緩；以下數據來自 macOS Apple Silicon 原生 Release。

## 範圍與判定

每個案例從同一份固定解碼的 extended-linear sRGB 輸入開始，使用同一組參數，分別跑過 Swift 與 C++ 的整條鏈：

**反應擴散顯影 → 藥水化學 → 光譜底片／光學印相 → 片種色彩 → 掃描 → sRGB16 成品量化 → 線性 sRGB → D65 Lab → CIEDE2000。**

判定採每張成品所有像素的 **最大 ΔE00 嚴格小於 2**，不採平均值代替。沒有拿 Swift 中間影像當作 C++ 輸入，也沒有為降低誤差而對齊、模糊或裁掉邊界。Swift 實際輸出 PNG16 再解碼；C++ 尚無 PNG 編碼器，以相同 sRGB16 量化邊界產生 PFM 供比較。

本次通過的是上述三模組串接。App 的乳劑、上游光學散射、色溫／色偏、局部明暗、其他風格與強度混合等仍未全部串入 C++。先前 194 組 App 完整配方參考仍有 **0 組可量測的 C++ 全流程成品**；不能用本次結果宣告整個 App 已達標。RAW 解碼也不屬於本次色差驗收。

## 本次結果（2026-09-30）

| 測試集合 | 案例數 | 最終成品最大 ΔE00 |
| --- | ---: | ---: |
| 真實 JPEG／Canon CR2 固定輸入，23 片種 × 6 組參數 | 276 | 0.878268 |
| 同上，曝光／褪色掃描／亮面紙／零強度分支 | 184 | 1.356777 |
| 1024×128 HDR、灰階、色邊與條紋，3 片種 × 2 組參數 | 6 | 1.132426 |
| 1023×127 及 127×1023，非整數顯影場與直向取樣 | 12 | 1.497445 |
| 合計 | **478／478 通過** | **1.497445 < 2** |

最差案例為橫向奇數尺寸、Velvia 50、顯影複合調整。數據表示目前測試矩陣通過，不代表任意照片、所有參數極值與未實作步驟皆有此色差上限。

另有 9 項 CTest／Smoke，包含有限數值、HDR／負通道保留、預乘透明度、常數場、來源不被修改、16-bit 階調、錯誤配方及成品閘門。Release 與 AddressSanitizer／UndefinedBehaviorSanitizer 都需通過；大型奇數尺寸另外跑 sanitizer 與成品比較。

## CPU 實作

- 保留既有 23 片種常數、13 波段感光／染料、LHTSS 色度重建表與掃描校準；資料由目前 Swift 原始碼匯出。沒有用一般 S 曲線替代光譜模型。
- 顯影採 12 次反應擴散、Q10 溫度、藥水供應及攪動模型；以 CPU 可分離濾波與離散熱核取代 Core Image。
- 底片包含層響應、互易律、耦合、保留銀、光源與紙材；掃描反算採有界 Newton 迭代。
- CPU Lanczos 在大幅縮小時分段減半，雙線性取樣使用 1/256 權重；兩者處理左上與 Core Image 左下座標的轉換，保留非整數縮放範圍的覆蓋率與透明邊界。先取樣反應場再求非線性生長比，避免邊緣誤差累積。
- 中間運算保留 extended-linear HDR 與負值；只有成品輸出在 SDR 邊界裁切。PFM 不含 alpha；輸出拒絕透明或非有限像素。
- 執行時僅使用 C++ 標準函式庫與隨附 MIT 授權的 nlohmann/json，沒有 Swift、Core Image、Metal、Accelerate 或其他 Mac 影像依賴。尚未進行 SIMD／多執行緒最佳化。

## 建置與操作

在儲存庫根目錄執行：

```sh
cmake -S experiments/PhotoCoreCpp -B build/photocore-cpp -DCMAKE_BUILD_TYPE=Release
cmake --build build/photocore-cpp
ctest --test-dir build/photocore-cpp --output-on-failure

build/photocore-cpp/photo_core_film \
  --input input.pfm --recipe recipe.json --output final.pfm
```

執行檔旁的 `film-data` 由 CMake 同步，也可透過 `--data` 指定。`--dump-stages 新目錄` 只供診斷，不影響最終成品判定。配方契約為 `schema: 1`、`scope: "film-development-scanner"`、`isPreview: false`，並提供 `style`、`strength`、`effects`。正式比較使用 Swift fixture 匯出的完整參數；不接受 App 全流程 scope。

## 重建參考與重跑

macOS 的 Swift 工具只用來匯出資料與參考成品。它編譯目前 Shared 原始碼，僅在建置目錄的顯影來源副本插入診斷讀回，不修改產品來源。`data/provenance.json` 記錄來源及資料雜湊；來源變動後應重建參考及 C++ 資料。

```sh
bash experiments/PhotoCoreCpp/tools/build_film_reference.sh
cmake --build build/photocore-cpp

# 兩份固定解碼輸入源自完整流程 fixture；也可以使用自己的線性 sRGB PFM。
# 不設篩選時，23 片種 × 10 參數 × 2 輸入，共 460 組。
build/photocore-cpp/film-reference fixtures build/photocore-cpp/film-all-fixtures \
  build/photocore-cpp/pipeline-fixtures/input-00.pfm \
  build/photocore-cpp/pipeline-fixtures/input-01.pfm

python3 experiments/PhotoCoreCpp/tools/verify_pipeline.py \
  build/photocore-cpp/film-all-fixtures/manifest.json \
  --scope film-development-scanner \
  --renderer build/photocore-cpp/photo_core_film \
  --comparator build/photocore-cpp/photo_core_compare \
  --report build/photocore-cpp/film-all-report.json
```

大型與奇數尺寸輸入可完全重建，不需外部照片：

```sh
python3 experiments/PhotoCoreCpp/tools/film_large_input.py build/photocore-cpp/film-large-input.pfm
python3 experiments/PhotoCoreCpp/tools/film_large_input.py build/photocore-cpp/film-odd-input.pfm --variant odd
python3 experiments/PhotoCoreCpp/tools/film_large_input.py build/photocore-cpp/film-portrait-input.pfm --variant portrait

PHOTOCORE_FILM_STOCKS=filmPortra400,filmHP5,filmVelvia50 \
PHOTOCORE_FILM_VARIANTS=default,development \
build/photocore-cpp/film-reference fixtures build/photocore-cpp/film-geometry-fixtures \
  build/photocore-cpp/film-large-input.pfm \
  build/photocore-cpp/film-odd-input.pfm \
  build/photocore-cpp/film-portrait-input.pfm
```

以相同 runner 比較 `film-geometry-fixtures/manifest.json` 即為另外 18 組。runner 驗證輸入／配方／Swift 成品雜湊，每次建立新 C++ 產物目錄，報告保存 renderer、比較器、資料檔雜湊及每個案例的平均／P95／P99／最大值／超標數。缺件、執行失敗或任何像素 ΔE00 ≥ 2 均回傳失敗。

本次原始報告位於 `build/photocore-cpp/film-report.json`、`film-branches-report.json`、`film-large-report.json`、`film-odd-report.json`；彙整為 `film-validation-summary.json`。這些是本機驗證產物，未納入正式 Release。

效率與記憶體量測、最佳化方式及重跑命令見 [CPU 效能驗證](PERFORMANCE.md)。

2026-09-30 對齊原生取樣語意後，另重跑 CPU 大型／奇數尺寸 18 組與 Vulkan 對照；結果見 [整體計算 Review](../../Vendor/PhotoCompute/COMPUTE_REVIEW.md)。
