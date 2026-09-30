# Swift 原版與 Vulkan 階段效能比較

2026-09-30，在 Apple M4 Pro、64 GiB、macOS 27.0 實測，**目前 Vulkan 版本比 Swift 原版慢**。Swift 原版使用 Core Image／Metal GPU，並不是 Swift CPU 逐像素運算；先前相對單執行緒 C++ CPU 的數十倍加速，不能當成相對 Swift 的加速。

此比較使用獨立測試工具，沒有整合 App、修改原版 Swift 演算法或建置 Windows。選取兩個較複雜的完整處理階段，並以相同線性輸入與配方分別呼叫現有實作：

- **顯影反應／擴散**：`PhotoFilmDevelopmentProcessor.apply` 對照 Vulkan `Pipeline::develop`，包含縮放、活性場、12 輪反應／兩軸擴散／補給，以及原尺寸生長合成。development amount 80、time 85、diffusion 0.6、agitation 15、temperature 28、activity 140、strength 1。
- **光譜底片**：`PhotoFilmSpectralProcessor.apply` 對照 Vulkan `Pipeline::spectral`，Portra 400、13 波段、負片反算、耦合模糊、銀保留；coupler amount 40、radius 0.5%、silver retention 20、reciprocity 35、12 秒、layer response 50、strength 0.6。兩邊皆延後獨立掃描渲染，完整參數保存在報告。

## 效能結果

先執行一次，再量測五次取中位數。下表 Vulkan **關閉驗證層**，MoltenVK fast math 關閉；兩邊均包含每次影像建立、GPU 工作及同步 CPU RGBAf 回讀。

| 尺寸 | 計算 | Swift 原版 | Vulkan | Vulkan 耗時／Swift 耗時 |
| --- | --- | ---: | ---: | ---: |
| 2048×1365（約 280 萬） | 顯影反應／擴散 | 23.42 ms | 41.02 ms | 1.75 倍 |
| 2048×1365（約 280 萬） | 光譜底片 | 7.01 ms | 35.59 ms | 5.08 倍 |
| 6000×4000（2400 萬） | 顯影反應／擴散 | 71.26 ms | 163.21 ms | 2.29 倍 |
| 6000×4000（2400 萬） | 光譜底片 | 64.70 ms | 412.53 ms | 6.38 倍 |

2400 萬像素時，Vulkan 顯影增加約 91.95 ms（129%）；光譜增加約 347.83 ms（538%）。這是兩個指定階段與參數的結果，不能直接相加推估 App 全流程或套用到所有底片。

| 尺寸／計算 | Swift 五次範圍 | Vulkan 五次範圍 | 開啟驗證層的 Vulkan 中位數 |
| --- | ---: | ---: | ---: |
| 280 萬／顯影 | 22.05–26.08 ms | 37.70–46.14 ms | 43.92 ms |
| 280 萬／光譜 | 5.86–13.45 ms | 31.72–40.28 ms | 30.25 ms |
| 2400 萬／顯影 | 65.52–71.50 ms | 158.06–167.22 ms | 164.86 ms |
| 2400 萬／光譜 | 61.83–70.07 ms | 400.08–427.60 ms | 387.95 ms |

驗證層開關兩組循序執行，沒有固定 GPU 時脈；其中開啟驗證反而較快，表示存在排程／時脈等執行波動，不能將兩者差值直接解讀成驗證層成本。兩種模式都明顯慢於 Swift，結論一致。

## 差距的證據與限制

2400 萬光譜案例，Vulkan 關閉驗證層最後一輪的 GPU timestamp：

| 工作 | GPU 時間 |
| --- | ---: |
| 耦合輸入複製 | 3.21 ms |
| 耦合 Gaussian X | 56.20 ms |
| 耦合 Gaussian Y | 192.74 ms |
| 光譜主核心（含反算） | 56.73 ms |

這是最後一輪各 dispatch 的 GPU 時間，**不是五次中位數，也不包含傳輸與主機成本**，不可直接替代表中的完整階段時間。單是兩軸模糊就約 248.94 ms，明確高於本輪光譜主核心。

Vulkan 的 Gaussian 為原尺寸直接兩軸卷積，sigma 30、半徑 120，每軸每像素 241 個取樣點；Swift 呼叫系統 `CIGaussianBlur`。顯影則有 12 輪、每輪 4 次 dispatch，現有 Vulkan runtime 每次提交都以 fence 等待，且另有縮放與原尺寸合成。這些是已確認的實作差異。Core Image 可能採用更有效率的模糊／排程與圖最佳化，但本測試未擷取其內部 GPU trace，不能聲稱已量出各項 Swift 最佳化的貢獻。

後續可優先量測 Gaussian 與記憶體存取、合併提交與減少同步等待。此輪只建立比較基準，未更改數學公式、降低迭代次數或為效能放寬色差。

## 正確性與計時契約

- Swift 6.4，以 `swiftc -O` 直接編譯未修改的 `PhotoStyleShared` 原始檔。使用 Apple M4 Pro Metal 裝置、extended-linear sRGB、RGBAf、`cacheIntermediates: false`，與 App 的核心影像格式及快取設定一致。每輪建立新 CIImage，同步 `context.render(toBitmap:)` 後才停止計時，並檢查核心可用及未直接回傳來源。
- Vulkan 使用同一現有 shader／階段函式，每輪重新上傳 CPU 來源、配置必要影像緩衝區、完成整個階段，再讀回 CPU。量測開關驗證層各一組；一般 CLI 與 Smoke 預設仍開啟一般及同步驗證。
- 兩者初始化另列，不計入暖機中位數。第一次呼叫另記於 JSON，不清除系統／驅動快取，因此不是全機冷啟動測試。PFM 讀寫、配方解析、成品雜湊、色彩量化與 ΔE 比較都在計時外；每輪最終物件釋放不計時。
- 使用既有 CPU 效能資料的兩張合成影像。來源、配方、Swift 原始碼、可執行檔及 SPIR-V 保留 SHA-256；兩後端循序執行，各案例交替測試次序，沒有同時競爭 GPU。
- 每個後端各次輸出一致；四組 Vulkan 開啟／關閉驗證層的原始浮點 PFM **SHA-256 完全一致**。開啟驗證時錯誤與警告均為 0，CPU 像素回退為 0。
- 階段輸出可能有 HDR 值；兩邊使用同一 CPU sRGB16 量化，之後比較整張 SDR 輸出的所有像素，不縮圖。這項色差只涵蓋該輸出域，不表示 HDR 原始浮點值逐位元相同。

| 尺寸／計算 | 階段 SDR 輸出最大 ΔE00 |
| --- | ---: |
| 280 萬／顯影 | 1.161502 |
| 280 萬／光譜 | 0.025613 |
| 2400 萬／顯影 | 1.250165 |
| 2400 萬／光譜 | 0.012023 |

四組皆 < 2。這是本次效能比較的階段輸出檢查，**不能替代完整流程最終成品驗收**；既有三模組 478 組最終成品驗證見 [Vulkan 三模組文件](VULKAN_FILM.md)。本輪重新建置及 12 項 CTest／Smoke 均通過。

完整量測：`build/photocore-vulkan-full/swift-vulkan-stages-oyukdqrj/report.json`，`completed: true`、`all_stage_delta_e_passed: true`。同目錄保存每組輸入配方記錄、原始 PFM、sRGB16 PFM、後端 sidecar 與日誌。程序 RSS 包含測試工具的反覆輸出檢查與檔案封裝，只供診斷，不能當成 App 記憶體基準。

## 重跑

先完成 [Vulkan 建置與環境設定](VULKAN_FILM.md) 及 [效能測試輸入](PERFORMANCE.md)，再於儲存庫根目錄執行：

```sh
bash experiments/PhotoCoreCpp/tools/build_swift_stage_benchmark.sh
cmake --build build/photocore-vulkan-full -j4
python3 experiments/PhotoCoreCpp/tools/compare_swift_vulkan_stages.py \
  --build build/photocore-vulkan-full --fixtures build/photocore-cpp --repeats 5
```

工具自動從 `runtime/environment.json` 載入 Vulkan 設定，每次建立全新 `swift-vulkan-stages-*` 目錄，並檢查 Swift 來源／執行檔與建置記錄相符。完整執行包含 Swift、Vulkan 關閉驗證、Vulkan 開啟驗證及輸出比對。
