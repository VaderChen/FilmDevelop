# 影像後端中介層

Go 宿主的 RAW 與計算預設為系統自動。macOS 使用 Core Image／Metal；Windows 先探測 Vulkan／GPU，再決定 GPU 或 CPU。Windows x64 已有本機安裝包並完成部分實機驗證，完整照片管線仍待移植，尚未發布 Release。

「設定 → 加速」由 Go 保存 RAW 與計算偏好，並依原生能力產生選項，不寫入照片配方。Go 透過共用 JSONL 契約呼叫平台引擎；macOS 引擎內仍由 PhotoBackendRouter 派送。

## 路由與平台邊界

| 功能 | 共用入口／契約 | macOS 實作 | Windows 實作狀態 |
| --- | --- | --- | --- |
| 原生影像計算 | `PhotoComputeProvider` | Core Image／Metal | C++／WIC 原片管線，完整效果仍待移植 |
| Vulkan 影像計算 | `PhotoComputeProvider` → `PhotoCompute.h` ABI | MoltenVK | C++ JSONL worker；已在 Windows 10 x64 GTX 1060 驗證 |
| 系統 RAW | `PhotoRAWDecodeProvider` | CIRAWFilter | WIC 可用解析器；解碼失敗時交由 LibRaw |
| 內建 RAW | `PhotoRAWDecodeProvider` | 既有 LibRaw C ABI | 共用 PhotoRAW／LibRaw 0.22.2，已驗證 DNG |

UI 不直接呼叫平台 API，也不使用平台名稱作為偏好值。macOS 原生、macOS Vulkan、Windows 自動／Vulkan 路徑在後端層區分；啟動時探測可用能力並核對保存的偏好。

## macOS 實際處理範圍

- 預覽、編輯來源預覽、底片懸停預覽、單張與批次匯出共用 renderer／管線。Vulkan 取代已移植的顯影反應擴散、顯影藥水、光譜底片、底片特性與正像掃描。
- 自適應曝光、乳劑、色溫、遮罩、AI、修復、裁切、外框等其餘階段保留原生處理，順序不變。不是整個 App 都改用 Vulkan；RAW 的 Bayer 解碼也未改成 Vulkan。
- 獨立實驗的 `Pipeline::process` 不是 App 完整配方。App 在既有各階段透過 C ABI 交接，不把整張照片丟進簡化的三模組 CLI，因此保留低強度混合、機身原片、裁切與後續效果。
- RAW 格式判斷、線性／機身顯影雙影像、半尺寸編輯、逐檔軟體解析回退搬到輸入層。軟體解析失敗時仍標記實際系統解析，不改寫使用者偏好。
- 切換計算後端先檢查 runtime；失敗維持原選擇。忙碌或預覽執行中拒絕切換。成功清除相關預覽快取、更新版本號並重新處理目前照片。
- 執行期 Vulkan 錯誤會向上拋出：主預覽顯示錯誤並停止使用失敗成品，匯出不會將原圖誤當成成功成品。未透過靜默原生回退冒充 Vulkan 成功。

## C ABI 2

`src/PhotoCompute.h` 使用固定寬度尺寸、UTF-8 JSON 請求及錯誤緩衝區；不跨語言邊界拋 C++ 例外。handle 持有 GPU 裝置、pipeline、光譜 LUT，內部 mutex 序列化使用，所有影像配置有 RAII 生命週期。

Swift 只快取成功建立的 engine。切回原生、舊預覽佇列完成與 App 關閉時移除快取擁有權；尚在運算的 provider 仍持有 engine，完成後才銷毀裝置與 LUT。清理不持有快取鎖，初始化失敗也不永久快取錯誤。Vulkan command buffer 使用 scope RAII，即使開始／結束錄製或讀取 timestamp 失敗，也會歸還 command pool 的配置。

schema 2 使用有向無環計算圖：節點只能引用輸入或較早的節點，中間影像保留在 GPU；依最後使用者計數即時釋放。完整計算圖只做一次影像上傳及一次讀回，錯誤時以 RAII 清理所有分支。schema 1 的單階段請求保留供獨立工具對照；新增 `photo_compute_transfers` 可讀取實際影像傳輸次數及 bytes。

影像交換契約為頂列在前、連續 RGBA Float32、預乘 alpha、extended-linear sRGB，保留負值及 HDR 高光。輸出由呼叫端持有；輸入／輸出不得重疊。階段交接不做 sRGB16 量化。裁切後的原點另傳給顯影顆粒，以保留座標語意；影像尺寸／非有限值／未知階段均拒絕。

App 的 Swift adapter 使用同一線性色彩空間，在原生／Vulkan 邊界交換位元圖並還原 CIImage 的 extent。顯影、藥水、光譜、底片特性與強度混合已串成 GPU 常駐計算圖；不再逐階段回讀再上傳。強度混合需要的原始分支、RAW 映射及灰階也在 GPU 完成。尚未移植的膚色／色調／HDR 等階段仍按原順序執行，之後的掃描為另一個 GPU 區段，不能越過原生階段擅自重排。

先前的 [Swift／Vulkan 階段效能比較](../../experiments/PhotoCoreCpp/SWIFT_VULKAN_PERFORMANCE.md) 是獨立計算基準，不能當成 App 完整匯出時間。此次改用常駐計算圖的傳輸驗證、全尺寸色差及端到端耗時，見 [整體計算 Review](COMPUTE_REVIEW.md)。

## 建置與部署

Xcode 的 `Build Compute` 執行 `scripts/build-compute-macos.sh`。開發機需要 CMake、glslang、Vulkan headers／loader、MoltenVK；預設取 Homebrew prefix，可用 `PHOTO_COMPUTE_PREFIX` 指定。此步驟不自動安裝套件。

- 建置 C++17 Release `libPhotoCompute.dylib`，arm64、macOS 最低版本跟隨 App。
- 將它與 MoltenVK 放入 App `Contents/Frameworks`；相依路徑改成 `@loader_path`，不引用開發機的 Homebrew 位置。
- 將 SPIR-V、底片資料及授權放入 `Contents/Resources/PhotoCompute`；動態程式庫簽章沿用建置身份，無身份時以 ad-hoc 簽章。
- 已安裝 App 不需要 Homebrew、Vulkan SDK 或獨立測試執行檔。App 的 MoltenVK instance 透過 layer settings 明確關閉 fast math；不修改整個程序的環境變數。一般與同步驗證仍由獨立 Smoke 工具開啟。

```sh
# 使用既有 Xcode 建置流程即可包含後端。
xcodebuild -project PhotoStyleApp.xcodeproj -scheme PhotoStyleApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

# 本機 App 完整管線 Smoke：比較 PNG16 最終成品，而非單一函式。
bash scripts/verify-macos-compute.sh
bash scripts/verify-macos-compute-edge.sh

# 本機記憶體 Smoke：渲染、切換、RAW、錯誤與 leaks。
bash scripts/verify-macos-compute-memory.sh
```

Smoke 使用測試 App 專用偏好，檢查切換／重建偏好／忙碌拒絕、JPEG、各底片預設與低強度、複合裁切及 RAW，並以獨立比較器驗證每張所有像素最大 ΔE00 < 2。完整矩陣與未驗證邊界記錄於實際結果報告，不以這些 Smoke 宣稱所有 App 參數組合已通過。

## 本輪驗證（2026-09-30）

Xcode 建置與設定選單 Smoke 通過。58 組 App 最終成品全部通過最大 ΔE00 < 2，其中 6048×4032 RAW 複合成品最大 1.59049477438；另有 CPU／Vulkan 各 18 組大型與奇數尺寸案例及 14 項 CTest 通過。GPU 常駐計算圖與原逐階段結果的最大 Float32 差為 0，實際影像傳輸由四次上傳／讀回降為各一次。

範圍、原始報告、單次效能對照與尚未移植的邊界見 [整體計算 Review](COMPUTE_REVIEW.md)。記憶體檢查的故障重現、修正與仍可在純原生管線重現的 Core Image 384 bytes 觀察，見 [記憶體檢查報告](MEMORY_AUDIT.md)。不以這些案例宣稱所有照片、參數與平台已通過。

## Windows 自動選擇與版本探測

Windows 系統預設先檢查 Vulkan Loader 與裝置 API 至少 1.1、計算佇列／容量，再執行 2×2 像素探測。合格獨立 GPU 優先；無可用 GPU、模組不存在或實際運算失敗時，從原始影像重新執行 CPU 管線。明確選取 Vulkan 時仍會回報錯誤。

ABI 2 新增相容的 photo_compute_device_info 查詢，回傳實際 GPU 名稱及 Loader／裝置版本；既有影像資料格式與處理函式不變。Windows 實機為 GTX 1060 6GB，Loader 1.3.204、裝置 1.2.133。版本不足、探測失敗及運算失敗已用隔離 DLL 故障注入驗證；測試 DLL 不隨產品封裝。
