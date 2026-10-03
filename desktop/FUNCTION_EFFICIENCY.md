# 函式層級效率與記憶體最佳化

日期：2026-10-03。基準為 `8bdd6790907a3634c440ab41a253fc6374587711`，本文件記錄 **1.26.1003 build 1503** 相較 build 1300 的函式最佳化。完整樣本、來源摘要及跨平台驗收見 [機器可讀報告](function-efficiency-report.json)；本輪與既有 [宿主快照最佳化](host-efficiency-report.json) 分開計算。

本輪更動 8 個產品原始碼檔案，涵蓋 Go 資料處理與 C++ CPU Gaussian。共用 HTML／CSS／JavaScript、配方契約、操作指令與影像參數均無差異。演算法不使用近似卷積、較低精度或較少驗證來換取速度。

## 逐函式處理

| 函式 | 修改及成本 | 保留的行為與驗收 |
| --- | --- | --- |
| recipes.cloneRecipe（新增，供 Edit／Normalize 共用） | 兩個 RawMessage 各自正規化及複製，省去大型修復資料的外層 JSON 解碼。 | 147 組與原 JSON 往返比對：HTML、Unicode、無效 UTF-8、null、無效 JSON、修復貼片及可變資料的獨立性。 |
| recipes.validateShape | 純量直接比對型別，巢狀物件或錯誤才配置完整欄位路徑。 | 必填、未知欄位、型別、可選結構規則不變。 |
| Library.document／validateDocument（抽出） | 已解碼物件共用完整結構與參數驗證。 | 仍拒絕錯誤版本、超大資料、無效修復 JSON、範圍及 HDR 曲線。 |
| Library.Edit | 移除編輯後第二次解碼；以原 HDR 是否可見的布林值取代整份曲線複製。 | 印相優先、原變更順序、裁切、HDR、主體判斷及最終驗證不變。 |
| Library.Normalize | 移除遷移後第二次解碼，直接驗證遷移物件。 | schema 1–12、原預設、欄位修復及回傳 JSON 保持一致。 |
| Library.Project／ProjectMany | 依已知欄位／配方數預先配置結果 map。 | 投影欄位、上限及識別檢查不變；ProjectMany 未另宣稱獨立加速比例。 |
| storage.ValidateMask／finiteMaskWeights | 直接檢查 Float32 指數位元，省去轉成 Float64。 | NaN／Inf 仍拒絕；負值、HDR、正負零及次正規值均保留。 |
| Store.ValidateMaskAsset | 一趟串流完成有限權重及 SHA-256 檢查，額外空間由 O(檔案大小) 降為最多 64 KiB 緩衝區。 | 標頭、尺寸、完整內容、摘要、中繼資料與截短／增長仍檢查。53 組資料對照原實作。 |
| Store.ImportMask／maskFileMatches | 既有資產以大小及串流摘要比對，不再整檔讀入。 | 不重寫相同內容；損毀資產重建；來源與修復版本保持個別中繼資料。輸入陣列仍由呼叫端持有。 |
| models.Paired | 從複製／排序及重複評分改為 O(n) 次評分；挑選狀態 O(1)。 | 單一候選、缺少候選、最高分同分與重複候選的結果不變；1,040 組對照原排序實作。 |
| photos.Scan／thumbnailIdentity／directoryOrder | Unicode 排序鍵每檔建立一次；依數量配置索引；整數直接寫入縮圖摘要輸入；0／1 張不建立排序器。 | 自然排序、大小寫、重音、數字、路徑決勝、穩定順序、檔案識別與縮圖鍵不變。排序鍵僅本次掃描存活。 |
| App.currentDefaults | 只快取目前自訂底片的一份投影，以 ID、基礎底片及完整 JSON 的 SHA-256 識別。 | 原地修改、改名、切換基礎底片、刪除及損毀回退均驗證；發布快照不洩漏快取的可變容器。 |
| film_cpu::gaussian | 內部像素採直接位移取樣，僅邊界像素走原邊界處理；不改權重及累加順序。 | 114 組逐位元比對，含單列／單欄、超大半徑、透明邊界、HDR、負值、alpha、來源不變及非法半徑。 |

## Go 函式量測

Apple M4 Pro、macOS 27.0、Go 1.27.0。每項測 3 次、每次至少 400 ms，取中位數；初始化和固定輸入建立不計時。耗時為 **µs/op**，配置為 **KiB/op**，正的下降比例表示改善。22 種輸入全部列出，未剔除較慢的極小案例。

| 函式／輸入 | 耗時：前 → 後（µs） | 耗時下降 | 配置：前 → 後（KiB） | 配置次數：前 → 後 |
| --- | ---: | ---: | ---: | ---: |
| Library.Validate（含 document／validateShape） | 27.725 → 24.420 | 11.9% | 15.43 → 11.61 | 368 → 270 |
| Library.Project | 34.697 → 29.386 | 15.3% | 24.60 → 16.46 | 379 → 274 |
| Library.Edit | 76.334 → 46.365 | 39.3% | 39.16 → 17.49 | 849 → 382 |
| Library.Normalize | 111.554 → 81.964 | 26.5% | 54.63 → 36.78 | 1278 → 911 |
| Library.Edit（2 MiB 修復資料） | 4,342.745 → 1,751.766 | 59.7% | 5,474.46 → 2,537.43 | 885 → 403 |
| App.currentDefaults（快取命中） | 156.035 → 0.639 | 99.6% | 80.03 → 0.00 | 1663 → 0 |
| ValidateMask，1×1 | 0.004 → 0.004 | -15.9% | 0.00 → 0.00 | 0 → 0 |
| Store.ValidateMaskAsset，1×1 | 13.505 → 13.551 | -0.3% | 1.76 → 1.12 | 12 → 13 |
| Store.ImportMask（既有資產），1×1 | 13.747 → 12.205 | 11.2% | 1.46 → 1.14 | 11 → 13 |
| ValidateMask，256×256 | 108.903 → 92.283 | 15.3% | 0.00 → 0.00 | 0 → 0 |
| Store.ValidateMaskAsset，256×256 | 539.692 → 460.463 | 14.7% | 1,033.26 → 65.10 | 12 → 13 |
| Store.ImportMask（既有資產），256×256 | 892.442 → 789.297 | 11.6% | 1,032.96 → 65.11 | 11 → 13 |
| ValidateMask，1024×1024 | 1,759.421 → 1,420.421 | 19.3% | 0.00 → 0.00 | 0 → 0 |
| Store.ValidateMaskAsset，1024×1024 | 8,448.460 → 7,515.110 | 11.1% | 16,393.26 → 65.10 | 12 → 13 |
| Store.ImportMask（既有資產），1024×1024 | 14,165.549 → 12,879.850 | 9.1% | 16,392.96 → 65.11 | 11 → 13 |
| models.Paired，4 個候選 | 9.553 → 4.288 | 55.1% | 2.05 → 0.88 | 96 → 42 |
| models.Paired，32 個候選 | 198.558 → 35.702 | 82.0% | 41.43 → 7.48 | 1914 → 350 |
| models.Paired，128 個候選 | 325.954 → 144.232 | 55.8% | 69.30 → 30.11 | 3130 → 1406 |
| photos.Scan，0 張照片 | 21.659 → 20.829 | 3.8% | 9.84 → 4.73 | 57 → 46 |
| photos.Scan，1 張照片 | 24.023 → 23.216 | 3.4% | 13.28 → 8.02 | 78 → 64 |
| photos.Scan，256 張照片 | 1,152.863 → 589.523 | 48.9% | 538.85 → 469.34 | 4189 → 3666 |
| photos.Scan，4096 張照片 | 28,648.228 → 12,785.348 | 55.4% | 9,179.61 → 7,941.75 | 65854 → 57612 |

1×1 的純記憶體 `ValidateMask` 實測為 3.622 → 4.199 **ns**，差 0.577 ns；表格以 µs 顯示會被捨入。極小檔案驗證耗時約持平，但配置下降。大型遮罩驗證及重複匯入的配置量降約 99.6%；`ImportMask` 的數據不包含呼叫端已有的完整輸入。

`currentDefaults` 數據只代表快取命中，第一次或配方變更仍需正規化與投影。新增的常駐成本是一份投影、兩個既有識別字串引用及 32-byte 摘要；不保留第二份原始 JSON，切回內建或失效時清除。**B/op 是每次呼叫累計配置，不能當作 App RSS 或峰值。**

目錄排序最初採連續增長的排序鍵緩衝區，雖加速卻增加配置；最後改成重用單一暫存緩衝區、保存各鍵的精確副本，並預先配置照片索引。這個增加記憶體的中間版本沒有保留。極小遮罩也依內容長度配置緩衝區，上限 64 KiB。

## 原生 Gaussian 量測

影像 1024×768。每輪預熱 3 次、量測 7 次，修改前後交替執行 3 輪，各 21 筆取中位數。Mac 使用 Apple clang 21；Windows 使用 MinGW GCC 16.2.0 交叉編譯後，在 **Windows 10／Intel i7-6700** 實機執行。兩者維持嚴格浮點選項。

| 平台 | sigma | 邊界 | 耗時：前 → 後（ms） | 耗時下降 |
| --- | ---: | --- | ---: | ---: |
| macOS arm64 | 1.5 | 透明 | 3.367 → 1.745 | 48.2% |
| macOS arm64 | 1.5 | 延展 | 2.733 → 1.740 | 36.3% |
| macOS arm64 | 4 | 透明 | 9.221 → 6.037 | 34.5% |
| macOS arm64 | 4 | 延展 | 7.550 → 6.064 | 19.7% |
| Windows x64 | 1.5 | 透明 | 25.391 → 20.507 | 19.2% |
| Windows x64 | 1.5 | 延展 | 21.882 → 19.098 | 12.7% |
| Windows x64 | 4 | 透明 | 55.296 → 33.804 | 38.9% |
| Windows x64 | 4 | 延展 | 48.464 → 33.318 | 31.2% |

此函式保持原有影像緩衝區數量及 O(寬×高) 空間；改善的是取樣成本，沒有把像素改為低精度或減少濾波半徑。這些百分比不是整體預覽或整張照片匯出的加速比例。

## 功能與跨平台驗收

- Go 全部內部測試套件通過 race，`go vet ./...` 通過；1,957 項 Swift 配方參考案例維持一致。
- C++ 底片不變量、平行工作者及 Gaussian 逐位元比較通過；相同三組另通過 AddressSanitizer／UndefinedBehaviorSanitizer。
- 真實 Mac Wails：47 項 UI Smoke 通過。
- 真實 Windows WebView2：一般 14 項、第一輪移植 21 項、第二輪移植 13 項，共 48 項通過。
- Windows 實際執行 recipes、storage、models、photos、application 五個 Go 測試套件。application 有 8 個環境／平台限定項目略過，完整名稱列於 JSON 報告，不當作通過項目。
- Windows **CPU 與 Vulkan 各 10 份**匯出：5 種底片 × JPEG／PNG，與 build 1300 的同一路徑逐檔 SHA-256 相同。CPU 驗證僅在隔離測試副本暫時移走 GPU 程式庫，完成後還原。
- 最後的 0／1 張照片及極小遮罩修正，已重跑全套 Go race／vet、Mac 47 項 UI；Windows 補跑受影響的 storage／photos／application 及 48 項 UI。配方、模型及 C++ 在首輪驗收後未變。

本輪沒有重跑所有 RAW／AI 模型矩陣，也未量測整個 App 的 RSS、Windows 11 或 MSVC。原生推論及平台像素差異仍依既有驗證範圍，不能由函式微基準推論。

## 重現方式

在專案根目錄執行：

```sh
go -C desktop test ./internal/recipes ./internal/storage ./internal/models ./internal/photos ./internal/application -run '^$' -bench 'Benchmark(RecipeFunctions|MaskFunctions|Paired|DirectoryScan|CustomDefaults)$' -benchmem -count=3 -benchtime=400ms
go -C desktop test -race ./internal/...
go -C desktop vet ./...
cmake -S experiments/PhotoCoreCpp -B build/function-check -DCMAKE_BUILD_TYPE=Release
cmake --build build/function-check --target photo_core_function_efficiency photo_core_film_verify photo_core_rows_verify
ctest --test-dir build/function-check -R '^(function_equivalence|film_invariants|parallel_rows_invariants)$' --output-on-failure
build/function-check/photo_core_function_efficiency
python3 engine/verification/desktop-smoke.py
```

比較基線時，在 `8bdd679` 的獨立副本放入相同基準測試，使用相同 Go／C++ 編譯器、參數、輸入與硬體，量測期間不要同時建置或執行其他負載。小尺寸補測使用修改前 `.bak` 的完整桌面模組副本；備份內容取自相同基線。Windows 測試必須實際執行交叉編譯的測試程式，編譯成功本身不代表驗收通過。

本輪本機原始證據保留於 `build/function-efficiency-20261003/`；正式比對樣本及結論另保存於本目錄的 JSON 報告。

## 正式發布

以上函式來源已納入 **1.26.1003 build 1503**。正式 Mac 標準與 Swift 相容 DMG 已完成簽章、公證；標準 Mac App 與 Windows x64 ZIP 另通過實機 Smoke。升版後 Mac 47 項、Windows 48 項 UI 通過，Windows 兩個 GGUF 推論及正式升級／失敗還原亦通過。成品 SHA-256 與驗證界線見 [發布驗證紀錄](RESTORATION.md)。函式量測沿用本報告原始樣本，未把新版包裝檢查重複計為新的效能量測。
