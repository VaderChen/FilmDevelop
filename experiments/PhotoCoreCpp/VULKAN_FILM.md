# Vulkan 底片／顯影／掃描移植

後續 App 整合已新增共用後端中介層與 C ABI，設定可實際切換原生／Vulkan；RAW 解析也統一經由路由器。這裡的 CLI 與歷史量測仍保留為獨立驗證，App 採用各階段接入，詳見 [App 後端中介層](../../Vendor/PhotoCompute/README.md)。

此為獨立 C++17／Vulkan Compute 測試程式 `photo_core_vulkan_film`。輸入上傳後，中間影像留在 GPU，完成三模組與 sRGB16 成品量化後才回讀；沒有接入 App，沒有執行 Windows x64 建置。

## 計算盤點

盤點對象是目前已移植的 C++ 核心，不將尚未移植的 App 功能算成已完成。

| 計算 | 原始位置 | Vulkan 實作 |
| --- | --- | --- |
| 區域曝光、全域曝光、亮部／峰值保護 | `core.cpp` | GPU 逐像素；每張一次的曝光曲線約束求解留在 CPU |
| RAW 亮部映射、六項式校色 | `core.cpp` | GPU 核心 API；另以不變量測試驗證，原三模組不自動插入此兩階段 |
| Gaussian 兩軸模糊、延展邊界 | `film_image.cpp` | GPU 兩次 dispatch，輸入與暫存分離 |
| Lanczos 縮圖、透明黑邊界 | `film_image.cpp` | GPU 分段減半＋末段兩軸 Lanczos；重用每列／欄的 CPU 預算權重 |
| 雙線性取樣 | `film_image.cpp` | GPU 明確取樣，使用與原生參考一致的 1/256 插值權重 |
| 活性場、非整數尺寸覆蓋率、鹽量／藥水初始化 | `film_development.cpp` | GPU |
| 12 輪反應、兩軸擴散、藥水補給 | `film_development.cpp` | GPU ping-pong 緩衝區，保留原迭代次數 |
| 取樣後的非線性生長比 | `film_development.cpp` | GPU；先取樣反應場，再計算比率 |
| 藥水密度、補償、銳度、顆粒、Lab 亮度、RGB 層反應 | `film_development.cpp` | GPU；保留原顆粒公式與座標方向 |
| 光譜 LUT 查表與插值、13 波段感光積分 | `film_data.cpp`、`film_spectral.cpp` | GPU storage buffer LUT |
| 密度曲線、層反應、互易律損失、耦合抑制 | `film_spectral.cpp` | GPU |
| 掃描感測積分、負片 unmix、正片／黑白分支 | `film_spectral.cpp` | GPU；保留最多 5 次評估／4 次 Newton 更新 |
| 光學印相、紙材曲線、銀保留、光源補償、散射／紙白 | `film_spectral.cpp` | GPU |
| 底片特性、掃描飽和／色溫／對比／黑位、色域限制 | `film_scanner.cpp` | GPU |
| 線性 RGB ↔ sRGB、16 位元量化 | `film_image.cpp` | GPU |
| 配方與資料驗證、I/O、光譜資料解析、每張固定係數 | `film.cpp`、`film_data.cpp`、`pfm.cpp` | CPU 控制與資料準備；不做逐像素效果 |
| CIEDE2000 驗收 | `verification/` | 保留獨立 CPU 比較器，避免 GPU 自己驗證自己的公式 |

UI 滑桿轉 EV、三維曝光約束、小型 diffusion／Gaussian／Lanczos 權重及光源矩陣準備只在參數或影像尺寸改變時執行，保留 CPU 不造成逐像素瓶頸。沒有以 CPU 影像處理回退掩蓋 GPU 不支援的案例。

完整 App 尚未移植的 AI 遮罩、修復、裁切、其他乳劑與色調功能仍不在此範圍；RAW 檔案解碼也不包含在本次 Vulkan 移植中。

## 執行架構

- `vulkan/pipeline.cpp` 排程與打包每張影像的參數；`vulkan/film.comp` 包含可重用的逐像素、濾波、反應擴散與光譜核心；`vulkan/runtime.cpp` 負責 Vulkan 資源、dispatch、同步、計時與記憶體統計。
- 所有影像計算使用 FP32。MoltenVK fast math 關閉，敏感反算運算使用 `precise` 限制融合。FP32 與 CPU double 的差異以最終成品最大 ΔE00 驗收。
- 一般 CLI 與 Smoke 的 Vulkan 一般與同步驗證預設開啟；獨立階段效能工具可明確關閉，並比對兩種模式的輸出。Shader 末尾工作群組有像素數 guard；超過工作群組數時可分段 dispatch，鄰域操作仍讀完整來源。超過 storage buffer 容量會明確失敗，尚未實作跨 buffer 的大圖分塊與 halo。
- 每個 dispatch 以 fence 與 memory barrier 保護；鄰域演算法使用獨立讀寫影像。一般執行只有輸入上傳與最後成品回讀；`--dump-stages` 額外回讀診斷影像，不應用於效能量測。
- 配方解析器由建置工具直接擷取現有 CPU 驗證程式碼，來源錨點改變時停止建置，避免兩個入口對無效配方有不同解讀。
- 原 CPU 實作與既有 unmix Smoke 保留。新目標預設關閉，不影響正式 App 或原 CPU 工具。

## 正確性

2026-09-30，Apple M4 Pro／MoltenVK：既有 Swift 參考成品 **478／478 組通過，所有像素最大 ΔE00＝1.49744469042 < 2**。

| 矩陣 | 組數 | 最大 ΔE00 |
| --- | ---: | ---: |
| 底片與主要參數 | 276 | 0.772831986539 |
| 曝光、低強度與紙材等分支 | 184 | 1.31091409509 |
| 大型合成影像 | 6 | 1.13242379487 |
| 奇數尺寸 | 12 | 1.49744469042 |

478 組的 Vulkan 錯誤、警告、CPU 像素運算回退均為 0。未關閉顆粒、減少迭代、縮小比較尺寸或提高 ΔE 門檻。

完整彙整報告：`build/photocore-vulkan-full/verification-0fetcswh/vulkan-summary.json`，包含四組矩陣、shader／來源雜湊及實際執行階段。平行建置最後修正為共用單一 shader／配方生成目標，並確認重建後執行檔與 SPIR-V 雜湊仍與上述驗證、效能量測一致。

新增曝光、RAW 亮部映射、校色、負值／HDR／alpha、來源保留的 GPU 對照，共 119,340 項檢查，最大正規化分量誤差 1.07966e-6（門檻 2e-5）。這項是基礎運算 Smoke，不取代上述完整成品矩陣。12 項 CTest 全部通過，SPIR-V 驗證通過。

另已新增 [Swift 原版／Vulkan 階段效能比較](SWIFT_VULKAN_PERFORMANCE.md)：2400 萬像素顯影約 71／163 ms，光譜約 65／413 ms。下表是對單執行緒 CPU 的比較，不能解讀為相對 Swift 的加速。

## 整體效能與記憶體

同機器、同輸入與配方、同一輪循序執行。CPU 為既有單執行緒版本，GPU 使用 FP32 且開啟 Vulkan 驗證。每個後端先暖機一次、再量測三次，輪次交替先後順序，表中為中位數。時間含程序啟動、資料載入、傳輸、所有影像階段、成品量化及 PFM 寫出；不含輸出雜湊與 ΔE 比較，沒有啟用診斷回讀。

| 像素／配方 | CPU 秒數 | Vulkan 秒數 | 整體加速 | CPU 峰值 RSS MiB | Vulkan 峰值 RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 280 萬／Portra400-default | 3.673 | 0.133 | 27.7 倍 | 177.6 | 125.8 |
| 280 萬／Velvia50-development | 2.635 | 0.130 | 20.3 倍 | 177.6 | 125.8 |
| 280 萬／Portra400-silver | 4.034 | 0.138 | 29.2 倍 | 177.6 | 125.9 |
| 280 萬／Delta3200-paper-glossy | 2.537 | 0.124 | 20.4 倍 | 177.6 | 125.6 |
| 2400 萬／Portra400-default | 32.644 | 0.669 | 48.8 倍 | 1179.5 | 772.8 |
| 2400 萬／Velvia50-development | 22.049 | 0.577 | 38.2 倍 | 1179.5 | 772.8 |
| 2400 萬／Delta3200-paper-glossy | 22.157 | 0.626 | 35.4 倍 | 1179.5 | 772.8 |

7 組效能案例最後成品相對同輪 CPU 的最大 ΔE00 為 **0.169406050894**，全部通過。CPU 與 GPU 不逐位元相同，但各自三次執行的成品 SHA-256 一致。這七組是大型合成輸入，未另宣稱它們已與 Swift App 全流程比較；前述 478 組才是 Swift 參考矩陣。

表中的 RSS 是 `wait4` 取得的單程序統計，不是 CPU＋GPU 的總實體記憶體。Vulkan 自身緩衝區配置峰值另記錄為約 **128.2 MiB／1098.9 MiB**（280 萬／2400 萬），包含來源、暫存與光譜資料；驅動內部配置未涵蓋。兩項統計可能重疊，不可直接相加，也不能把 RSS 降幅解讀成總 GPU 記憶體節省。

原始效能報告：`build/photocore-vulkan-full/performance.json`，`completed: true`。保留每次耗時、CPU 秒數、RSS、各 GPU 階段計時、配置峰值及最終成品 ΔE。這是獨立 CLI 在 Apple M4 Pro 的結果，沒有測量 App 互動預覽或 Windows GPU，也未與多執行緒／SIMD CPU 比較。

## 建置與重跑

沿用 [Vulkan Smoke 的工具鏈與環境設定](VULKAN_SMOKE.md)。從專案根目錄執行：

```sh
cmake -S experiments/PhotoCoreCpp -B build/photocore-vulkan-full \
  -DCMAKE_BUILD_TYPE=Release -DPHOTOCORE_VULKAN_FILM=ON \
  -DCMAKE_PREFIX_PATH="$(brew --prefix)"
cmake --build build/photocore-vulkan-full -j4
python3 experiments/PhotoCoreCpp/tools/configure_vulkan_macos.py build/photocore-vulkan-full/runtime
source build/photocore-vulkan-full/runtime/vulkan.env
ctest --test-dir build/photocore-vulkan-full --output-on-failure
spirv-val --target-env vulkan1.1 build/photocore-vulkan-full/film.comp.spv

python3 experiments/PhotoCoreCpp/tools/verify_vulkan_film.py \
  --fixtures build/photocore-cpp --build build/photocore-vulkan-full

python3 experiments/PhotoCoreCpp/tools/benchmark_film.py \
  build/photocore-cpp/performance/manifest.json \
  --renderer cpu=build/photocore-vulkan-full/photo_core_film \
  --renderer vulkan=build/photocore-vulkan-full/photo_core_vulkan_film \
  --repeats 3 --comparator build/photocore-vulkan-full/photo_core_compare \
  --report build/photocore-vulkan-full/performance.json
```

成品的 `.vk.json` 保存裝置、每個 dispatch 的階段／時間、Vulkan 配置峰值與驗證結果。單獨的 `passed: true` 只表示 GPU 執行成功；顏色正確性仍必須由成品比較器判斷。

2026-09-30 App 整體 Review 補充：大幅縮小及插值權重已依原生脈衝／取樣測試對齊，App 也改為 GPU 常駐計算圖。最新全尺寸成品與傳輸次數結果見 [整體計算 Review](../../Vendor/PhotoCompute/COMPUTE_REVIEW.md)。以上舊效能數字保留為當時實作的歷史基準。
