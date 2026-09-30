# Vulkan Compute Smoke

本文件保存初期 unmix Smoke；後續完整影像計算的移植與驗證見 [Vulkan 三模組移植](VULKAN_FILM.md)。

2026-09-30，Apple M4 Pro／macOS，MoltenVK 1.4.2：**Smoke 通過**。只在獨立實驗程式中將光譜負片的 `unmix()` 改由 Vulkan Compute 執行；未整合 App，Windows x64 建置仍暫緩。

## 驗證方式

GPU shader 使用 FP32，保留 CPU 的 13 波段、最多 5 次誤差評估／4 次 Newton 更新、停止門檻與步幅限制。此裝置不支援 Vulkan `shaderFloat64`，因此直接驗證 FP32 的成品誤差，不假設有 FP64。

測試先執行 CPU 底片／顯影／掃描流程，擷取實際 `unmix()` 輸入及純 CPU 最終成品，再批次提交 GPU。第二次執行相同流程時，在相同呼叫位置使用 GPU 結果，逐筆檢查輸入順序，禁止退回 CPU 反算。成品維持既有 sRGB 16 位元量化邊界，對所有像素計算最大 CIEDE2000，門檻嚴格小於 2。

因此，既比較單一反算分量，也比較**底片、顯影、掃描串接後的最終成品**；包含與既有 Swift 參考成品的獨立比較。這是 GPU 與 CPU 混合流程的 Smoke，不代表 App 全流程、全 GPU 移植或既有 478 組全部完成 GPU 驗證。

接線由 `prepare_vulkan_smoke.py` 在建置目錄產生 `film_spectral.cpp` 測試副本，只替換一處呼叫。原始 CPU 核心檔案未改動，CMake 選項預設關閉。

## 實測結果

| 檢查 | 結果 |
| --- | --- |
| Vulkan 開啟後 CTest | 11／11 通過 |
| Vulkan 關閉後原有 CPU CTest | 9／9 通過 |
| GPU 混合流程與 Swift 成品 | 10／10 通過，最大 ΔE00 **0.955630064505** |
| GPU 混合流程與純 CPU 成品 | 最大 ΔE00 **0.006932761935** |
| unmix 分量與 CPU 浮點參考 | 最大絕對誤差 **1.90735e-6**，Smoke 門檻 0.001 |
| Vulkan 一般及同步驗證 | 0 錯誤、0 警告 |
| 重播時 CPU 反算回退 | 0 次 |
| SPIR-V 驗證 | `spirv-val --target-env vulkan1.1` 通過 |

10 組矩陣涵蓋 Portra 400、Portra 800、Ektar 100、Lomo Purple、Bleach Bypass、Vision 500T 的預設、曝光、顯影、掃描及留銀配方，使用既有參考圖的原尺寸：每張 24,384、24,576 或 129,921 像素，沒有為比較而縮圖或修改配方。

每組額外檢查 1／63／65 個元素的 dispatch、尾端 64 個 sentinel、有限值、有效元素全部寫入，以及兩次完整 dispatch 結果一致。CTest 另以 17×5 的 HDR 色彩輸入測試，並驗證既有輸出檔不可覆寫、未執行反算的正片配方必須失敗。

初選的 Ektar 100 `lights` 案例因 `scanner_profile=off` 不呼叫 `unmix()`，測試正確拒絕，初次矩陣為 9／10；之後選用原有 `scanner` 參考案例補足 GPU 覆蓋，未更改原配方或降低驗收標準。關閉掃描器、黑白、正片等沒有執行此 GPU 核心的案例不能算 GPU 通過。

本機完整報告：`build/photocore-vulkan-smoke/matrix-ov7mag29/report.json`。保存每組成品量測、GPU 執行資訊、來源與配方雜湊、SPIR-V、執行檔及執行期函式庫 SHA-256；每張成品旁亦有 `.gpu.json`。初次未通過的報告仍保留於 `matrix-vz86ronl`。

## 重跑

在專案根目錄執行；本機已安裝下列工具。MoltenVK 透過 Metal 執行 Vulkan，Smoke 不需要 App 的 Metal／Core Image 入口。

```sh
brew install molten-vk vulkan-headers vulkan-loader glslang vulkan-validationlayers
cmake -S experiments/PhotoCoreCpp -B build/photocore-vulkan-smoke \
  -DCMAKE_BUILD_TYPE=Release -DPHOTOCORE_VULKAN_SMOKE=ON \
  -DCMAKE_PREFIX_PATH="$(brew --prefix)"
cmake --build build/photocore-vulkan-smoke -j4

python3 experiments/PhotoCoreCpp/tools/configure_vulkan_macos.py \
  build/photocore-vulkan-smoke/runtime
source build/photocore-vulkan-smoke/runtime/vulkan.env
ctest --test-dir build/photocore-vulkan-smoke --output-on-failure
spirv-val --target-env vulkan1.1 build/photocore-vulkan-smoke/unmix.comp.spv

python3 experiments/PhotoCoreCpp/tools/run_vulkan_smoke.py \
  --fixtures build/photocore-cpp \
  --build build/photocore-vulkan-smoke \
  --environment build/photocore-vulkan-smoke/runtime/environment.json
```

最後一步需要既有 `film-fixtures`、`film-branches-fixtures`、`film-odd-fixtures` 的 Swift 參考資料。缺檔、SHA-256 不符、沒有 GPU、驗證層缺件、GPU 未執行或成品超標都會失敗，不能略過算通過。一般 CTest 自行產生小型輸入，不依賴這三組參考資料。

設定工具僅在建置目錄建立驅動與驗證層 manifest 副本，將函式庫改為絕對路徑，避免 Homebrew 的相對載入路徑失敗；不修改系統 manifest，也不依賴 `DYLD_LIBRARY_PATH`。固定 `MVK_CONFIG_FAST_MATH_ENABLED=0`，並強制啟用 Khronos 驗證層及同步驗證。

## 效率與後續範圍

這個驗證工具故意跑兩次 CPU 流程，並保存擷取資料，不能用總時間或記憶體推估正式 GPU 後端。報告中的 GPU timestamp 只涵蓋 dispatch 周邊指令，不含資源配置、上傳／下載、管線編譯及其他 CPU 階段；驗證層也可能影響時間。獨立效能量測另見 [Vulkan 效能量測](VULKAN_PERFORMANCE.md)，尚未宣稱解決原先 3X 秒的整體耗時。

下一步可以將光譜像素處理改成常駐 GPU 資料，再搬移顯影與模糊等高成本步驟，使用相同最終成品 ΔE 門檻擴大矩陣。正式效率比較應包含資料傳輸、冷／暖啟動、全解析度照片及峰值記憶體。目前 Smoke 超出單次 dispatch 或 storage buffer 的裝置限制會明確失敗，尚未實作大圖分批；本機 2400 萬像素仍可單次提交。
