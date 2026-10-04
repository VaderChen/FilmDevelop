# 液化函式層級最佳化

本次基線為液化已整合至開發版後、最佳化前的工作目錄。比對不使用尚未含液化的 Release 或 Git HEAD。功能、介面、筆刷參數、推移／還原、逐筆保存與復原流程維持不變；不降低網格密度、色彩精度或翻折檢查門檻。

## 前端函式

量測環境為 Apple M4 Pro、Node.js v26.6.0；核心以相同 V8 執行環境暖機後交錯量測 9 組，取中位數。以下為固定輸入的函式耗時，不是整個 App 的速度保證。

| 函式與案例 | 修改前 | 修改後 | 變更 |
| --- | ---: | ---: | --- |
| `validCandidate`，局部 33×33 節點 | 0.0235 ms | 0.0066 ms | 每個角共用 X/Y 候選判斷，移除重複 closure 呼叫 |
| `fromData`，局部筆畫 | 1.014 ms | 0.422 ms | 驗證時一併收集影響範圍，重載後只重算相關區域 |
| `toData`，局部筆畫 | 1.296 ms | 0.068 ms | 陣列預先配置最終長度，以直接迴圈序列化 |
| `renderWarp`，重載局部筆畫 | 1.668 ms | 1.539 ms | 每列共用垂直權重，維持原有運算次序 |
| 完整 70 px 筆畫 | 0.880 ms | 0.638 ms | 包含筆畫開始、移動與提交，不含宿主處理 |

`read`、`capture` 的演算法維持原樣，不宣稱加速。混合測試中短時間配置函式會受 GC 影響；`capture` 獨立重測為 0.01078／0.01065 ms，區間重疊。函式 profile 包含子函式時間，不可加總成整體耗時。

1024×683 網格的 `toData` 輸出，在 GC 後保留的 JavaScript heap 平均每份約由 907,707 降至 707,468 bytes；網格、scratch、RGBA 緩衝區及歷史預算不增加。這是該物件的量測，並非整個 App 的 RSS。

控制器另以 Chromium 和固定的最佳化前核心隔離量測，確認改善來自控制器：

| 函式／工作 | 修改前 | 修改後 |
| --- | ---: | ---: |
| `ensureSource`，同來源 20 次換網格 | 20 次解碼／讀回像素 | 0 次 |
| 上述累計像素讀回量 | 60 MiB | 0 |
| `redraw`，20 次內容及幾何皆未變 | 20 次 `drawImage` | 0 次 |
| `pointermove`，40 包 × 32 個合併事件 | 2,720 次矩形量測 | 80 次 |

快取的是未液化的來源像素；宿主回傳的網格仍重新驗證。來源、照片或取樣尺寸改變會重建；關閉工具釋放像素。每個滑鼠事件只量測一次影像及畫框，所有合併事件仍逐一處理。`ImageData` 共用既有輸出陣列；畫布、DPR、位置、尺寸、網格任一改變均重新繪製。

## 宿主與原生函式

Go `liquifyRevision` 只快取目前不可變網格的修訂鍵；`shareLiquifyMeshes` 先比對指標／內容，避免 38 款底片重複雜湊。`trimLiquifyHistory` 一次統計引用後批次裁剪，保留既有順序與 32 MiB 上限。

`NormalizeLiquify` 預配數值陣列、在驗證時共用節點座標。Library 對最後一份有效網格做內容驗證快取，`cloneRecipe` 仍複製私有位元組，外部修改不會污染快取；內容改變及錯誤資料仍完整驗證。快取最多保存一份驗證內容和一份標準 JSON，各不超過 8 MiB；相同內容共用儲存。這是有上限的常駐記憶體交換，不代表全部常駐記憶體下降。

Go 1.27.0、1024×768 網格、38 底片，3 次中位數如下。Normalize／Edit／Project 是相同有效內容的暖機案例；配置量是每次呼叫的累計配置，非峰值或 RSS。

| 函式／案例 | 修改前 → 修改後 | 累計配置 bytes/op，前 → 後 |
| --- | ---: | ---: |
| `liquifyRevision`，連續查詢同一網格 | 0.717 ms → 5.86 ns | 128 → 0 |
| `shareLiquifyMeshes`，38 個相同指標 | 27.160 → 0.00176 ms | 11,688 → 6,824 |
| `shareLiquifyMeshes`，38 份相同內容 | 27.105 → 1.447 ms | 11,688 → 6,824 |
| `trimLiquifyHistory`，100 筆 × 38 底片 | 2.190 → 0.137 ms | 258,536 → 13,928 |
| `NormalizeLiquify`，完整冷驗證 | 10.297 → 10.178 ms | 12,301,406 → 9,193,948 |
| Library `Normalize` | 12.779 → 0.262 ms | 25,093,640 → 2,188,067 |
| Library `Edit` | 12.765 → 0.228 ms | 24,483,878 → 2,168,541 |
| Library `ProjectMany`，38 底片 | 394.140 → 2.493 ms | 468,262,296 → 642,276 |

冷驗證耗時差距很小，主要收益是減少約 25% 配置；快取命中的數字不可套用到每次都換新網格的情境。

Swift `PhotoLiquifyMesh.init(from:)` 一次建立不可變的位移圖、identity 與最大位移，`applying(to:)` 重用資料。每份有效網格多保留一份 RGBAf map，取代每次 applying 都建立 Float 陣列及 Data；沿用原 Metal kernel，色域、預乘 alpha 與插值順序不變。曾評估的空白 cell 捷徑在三組暖機對照沒有一致收益，因此未保留。

C++ `LiquifyMesh` 將 JSON 陣列查找移出節點迴圈，建立每列有變形的連續區段；`apply_liquify` 預算各軸座標，跳過零位移 cell。稀疏網格只暫存受影響像素，完成所有讀取才回寫原影像；密集網格沿用分離輸出影像。同一 Windows render job 的 `render_style`、遮罩、深度圖與編輯預覽共用已驗證網格，避免重複建構。

原生固定 1024×768 參考網格，輸出 2048×1536；C++ 在 macOS 本機執行共用演算法，並非 Windows 實測。計時前先建立輸入影像，函式計時包含額外暫存、取樣及回寫。暖機 3 次後，建構取 7 次、取樣取 9 次中位數。

| 函式／案例 | 修改前 → 修改後 |
| --- | ---: |
| C++ `LiquifyMesh`，局部網格建構 | 3.0288 → 0.5167 ms |
| C++ `apply_liquify`，局部筆畫 | 2.6490 → 0.2418 ms |
| C++ `apply_liquify`，分散筆畫 | 2.7403 → 0.4374 ms |
| C++ `apply_liquify`，全圖網格 | 4.5814 → 3.1819 ms |
| Swift `applying(to:)`，建圖 | 0.1194 → 0.0011 ms |
| Swift 建圖及完整 Metal 渲染 | 3.0664 → 3.0480 ms |

局部案例的額外像素暫存由 50,331,648 降至 925,696 bytes；另增加 71,696 bytes 的軸座標／列偏移，以及約 5 KiB 的網格活動區段。密集案例保留全圖暫存，不宣稱同樣的記憶體降幅。

Swift 此例每份網格保留 793,616 bytes 的 map 資料，取代每次 applying 的 1,587,232 bytes 中間陣列／Data。完整 Metal 渲染含 GPU 與讀回成本，差距很小且有波動，不宣稱穩定的 GPU 加速。上述資料 payload 皆未含框架或配置器開銷。

## 驗證與重現

核心差分涵蓋 7 種尺寸／間距、831 次網格比對、168 次 RGBA 逐位元組比對、126 次序列化，以及取消、復原、重做、局部還原、減半重試、翻折拒絕及非法資料。控制器另比對 20 次版本更新、尺寸改變、identity、快速復原再重做、來源切換及關閉重開的畫布像素。

2026-10-04 驗證結果：核心 22 項、Chromium／WebKit 各 20 項、原生 12 項 Smoke 通過；30 組原生前後 Float32 RGBA 逐位元組相同。Go 全部有測試的 12 個 internal 套件 race 與 vet 通過；包含快取內容被修改、並行驗證、clone 隔離與歷史順序等價測例。

真實 Go／WKWebView／Swift App 兩次啟動完成液化、復原／重做、保存重開及正式匯出，1536×1024 PNG 在重開前後逐位元組相同，未偵測 Go 資料競爭。該輪只完成 Windows 宿主與原生引擎交叉編譯；後續 build 1004 發佈前已完成 Windows 10／GTX 1060 實機液化、筆刷滾輪、保存重開、原生取樣與 CPU／Vulkan 匯出，詳見[正式成品驗證](../../desktop/RESTORATION.md)。

本機證據位於 `build/liquify-optimization/`，包含修改前來源快照、SHA-256、原始量測與 Smoke 報告。`build/` 不進版控；要重現前後量測，須保留自己的修改前來源快照，不可以已最佳化的檔案覆蓋基線。

```sh
node --expose-gc engine/verification/liquify-core-performance.mjs
node engine/verification/liquify-controller-performance.mjs
python3 engine/verification/liquify-native-performance.py
node engine/verification/liquify-core-smoke.mjs
node engine/verification/liquify-ui-smoke.mjs build/liquify-optimization/ui-chromium
LIQUIFY_BROWSER=webkit node engine/verification/liquify-ui-smoke.mjs build/liquify-optimization/ui-webkit
python3 engine/verification/liquify-native-smoke.py --windows-build
python3 engine/verification/liquify-desktop-smoke.py
go -C desktop test -race ./internal/...
go -C desktop vet ./internal/...
go -C desktop test ./internal/application ./internal/recipes -run '^$' -bench Liquify -benchmem -count 3
```

瀏覽器測試需要 Playwright；可用 `PLAYWRIGHT_MODULE` 指定模組，`LIQUIFY_BROWSER_EXECUTABLE` 指定已安裝的瀏覽器執行檔。瀏覽器 Smoke 使用正式共用 Web，宿主回覆由測試模擬；實際保存與匯出另由桌面 Smoke 驗證。Windows 實機專項使用 `liquify-windows-smoke.ps1`，另需同版正式解壓 App、Smoke 宿主、原生探針、合成測資及已驗證修復模型。上方效能表仍為 Mac 量測；後續 Windows 執行證據不改變其量測平台。
