# CPU 效率與記憶體驗證

本文件保留 CPU 最佳化結果；後續 GPU 常駐流程與 CPU 的端到端比較見 [Vulkan 三模組移植](VULKAN_FILM.md)。

本次在三模組成品色差驗收通過後，量測 `photo_core_film` 的執行效率與記憶體，再進行保留原有數值運算的最佳化。範圍仍為獨立 C++ 顯影／底片／掃描，不含 App 整合或 Windows 建置。

## 量測方法

- 環境：Apple M4 Pro、12 個邏輯核心、64 GiB 記憶體，macOS 原生 CMake Release。程式維持單執行緒，未啟用 fast-math。
- 同一個 runner 循序啟動舊版與新版，不平行執行量測。每個案例／版本先暖機一次，再量測三次；輪次交換先後順序，報告取中位數並保留全部原始值。
- 時間涵蓋程序啟動、底片資料載入、PFM 讀取、所有處理階段、sRGB16 量化及 PFM 寫出；是 CLI 端到端時間，不是單一核心函式時間。使用暖快取，未強制清除作業系統磁碟快取。
- 以 `wait4` 取得每個子程序的 user＋system CPU 秒數及峰值 RSS。macOS 的 RSS 單位為 bytes，Linux 則轉換 KiB；不是 Python runner 自身，也不是多次執行累積的峰值。
- 輸入含 HDR、灰階、色邊與條紋，以固定最近鄰展開至 2048×1365（約 280 萬）與 6000×4000（2400 萬）像素。測試資料準備、雜湊及色差比較不計入時間。
- 報告記錄來源、配方、執行檔及資料雜湊。每次成品也取 SHA256，確認重複執行的確定性，以及新舊版本是否逐位元一致。

## 本次結果（2026-09-30）

七組效能案例的成品皆與原版逐位元一致。下表記憶體為三次「單程序峰值 RSS」的中位數，非累積值。

| 像素／案例 | 原版秒數 | 最佳化秒數 | 耗時降低 | 原版峰值 MiB | 最佳化峰值 MiB | 記憶體降低 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 280 萬／Portra400-default | 4.19 | 3.79 | 9.6% | 274.7 | 177.6 | 35.4% |
| 280 萬／Velvia50-development | 3.12 | 2.72 | 12.6% | 274.7 | 177.6 | 35.4% |
| 280 萬／Portra400-silver | 4.55 | 4.15 | 8.6% | 274.7 | 177.6 | 35.4% |
| 280 萬／Delta3200-paper-glossy | 3.01 | 2.60 | 13.5% | 360.1 | 177.6 | 50.7% |
| 2400 萬／Portra400-default | 36.36 | 33.16 | 8.8% | 1923.4 | 1179.5 | 38.7% |
| 2400 萬／Velvia50-development | 25.57 | 22.35 | 12.6% | 1923.4 | 1179.5 | 38.7% |
| 2400 萬／Delta3200-paper-glossy | 25.61 | 22.37 | 12.7% | 2655.9 | 1179.5 | 55.6% |

量測顯示耗時降低 8.6～13.5%，峰值 RSS 降低 35.4～55.6%。數據只代表上述機器及測試矩陣；仍須針對實際部署環境與照片量測。原始記錄為 `build/photocore-cpp/performance/comparison.json`，品質對照與改善百分比彙整為同目錄的 `summary.json`。

## 改動

1. **移轉緩衝區所有權。** 逐像素階段沿用已擁有的影像儲存空間，避免串接時不斷複製整張 RGBA。外部傳入 lvalue 仍會先複製，不改原圖；傳入 `std::move(image)` 或暫存影像則直接承接。
2. **縮短暫存影像生命週期。** 只有需要鄰域資訊時才建立導引圖；顯影縮圖與耦合導引使用完便釋放。反應場僅依賴同一像素的部分直接更新，擴散仍使用獨立來源。
3. **重用濾波緩衝區。** Gaussian 兩軸使用兩個緩衝區交替；Lanczos 不先複製完整來源，且同一軸座標共用一組係數，保持原有加總順序及透明邊界。
4. **移出固定運算。** 光譜感度、正規化分母、密度偏移與中性掃描參數每張影像準備一次；逐像素轉換改為可內嵌模板，避免每個像素的 `std::function` 呼叫。
5. **按列讀寫 PFM。** 將每像素／每通道的串流呼叫合併為一列，同時保留大小端、scale、上下方向、有限數值及透明度檢查。

沒有降低影像尺寸、減少光譜波段或 Newton／顯影迭代，也沒有改用近似數學函式。反應擴散及其他鄰域處理未改成不安全的原地濾波。

## 正確性

既有 **478／478 組 Swift 對照全部通過，最大 ΔE00＝1.49744505936**。這 478 組的最終 PFM 與最佳化前 SHA256 全部相同，因此本次對這個矩陣增加的成品色差為零。

Release 與 ASan／UBSan 的 9 項 CTest 均通過，包括原圖保留、HDR／負值／alpha、常數場、PFM 大端序與 scale、成品閘門及錯誤配方等。色差矩陣的範圍與限制見 [FILM_CPU.md](FILM_CPU.md)。效能用大型合成圖另外確認新舊輸出一致；未據此宣稱這些大圖已與 Swift 完整 App 流程對照。

## 重跑

先依 `FILM_CPU.md` 建立基準成品與 fixture，並在最佳化前保留獨立的 renderer 及旁邊的 `film-data`。本次基準執行檔為 `build/photocore-cpp-perf-baseline/photo_core_film`，來源快照另存於 `build/photocore-cpp/performance/baseline-source.tar.gz`。

```sh
python3 experiments/PhotoCoreCpp/tools/prepare_film_benchmark.py build/photocore-cpp

python3 experiments/PhotoCoreCpp/tools/benchmark_film.py \
  build/photocore-cpp/performance/manifest.json \
  --renderer baseline=build/photocore-cpp-perf-baseline/photo_core_film \
  --renderer optimized=build/photocore-cpp/photo_core_film \
  --repeats 3 \
  --report build/photocore-cpp/performance/comparison.json
```

準備工具使用前次的 `film-fixtures` 六變體與 `film-branches-fixtures` 四變體目錄；若只產生合併的 `film-all-fixtures`，可直接以自有 manifest 指定等效輸入與配方。manifest 的每個 case 必須提供 `id`、`input`、`recipe` 及兩者的 SHA256，路徑相對 manifest 目錄。

正式報告必須有 `completed: true`，不能把中途中斷留下的部分結果當成整批完成。量測時不要同時編譯或執行其他重負載工作；不同 CPU、作業系統、編譯器與快取狀態的時間不宜直接合併。
