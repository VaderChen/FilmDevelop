# 獨立液化筆刷原型

此目錄保留最初用來驗證「以筆刷拖曳，局部推移照片」的獨立原型，仍可單獨啟動。後續經確認後，正式實作已移入 `PhotoStyleApp/Web/liquify-*`，並串接 Go 宿主與兩平台影像引擎；開發版 App 的按鈕位於修復筆刷左邊。下列 1,024 像素輸出限制只適用本目錄的獨立原型，App 匯出使用原始解析度。版本與 Release 尚未更新。

## 啟動與操作

在專案根目錄執行（需要 Python 3）：

```sh
python3 experiments/Liquify/serve.py --open
```

Windows 若 Python 的命令名稱為 `python`，可改用：

```powershell
python experiments/Liquify/serve.py --open
```

預設網址為 <http://127.0.0.1:8766/>；服務僅監聽本機。可用 `--port 8767` 改連接埠，或 `--port 0` 自動選擇。終端按 Ctrl+C 關閉。請透過 HTTP 開啟，避免直接開啟 HTML 時瀏覽器阻擋 ES module。

1. 先拖曳內建格線圖，或按「開啟照片」選擇本機圖片。
2. 「推移」沿筆刷拖曳方向扭曲；「局部還原」逐步恢復筆刷範圍內的形狀。
3. 半徑控制範圍，強度控制每段拖曳的變形量；強度 0 不改圖、不新增歷史。
4. 使用「復原／重做」，或 Ctrl/Cmd+Z、Ctrl/Cmd+Shift+Z。Esc 取消尚未完成的筆畫。
5. 按住「比較原圖」，或在畫布上按住空白鍵，檢查變化；放開後恢復編輯結果。
6. 「下載 PNG」保存目前預覽尺寸的結果；「全部還原」清除所有變形與歷史。

## 範圍與限制

- 目前實作推移、局部還原，並非 Photoshop 液化所有工具的完整替代品；沒有臉部偵測、凍結遮罩、膨脹、收縮或旋轉工具。
- 瀏覽器載入 PNG、JPEG、WebP 等其可解碼格式；單檔上限 40 MiB。照片不會上傳到伺服器。
- 編輯與下載長邊最多 1,024 像素、使用 8-bit RGBA；不處理 RAW、HDR、16-bit、原始尺寸重播或原圖 metadata 保留。
- 網格固定影像邊界，靠近邊緣時影響逐漸減弱。非常強烈的反覆變形會自動限制增量，避免網格翻折。
- 幾何核心可接受最多 4,194,304 像素、寬高至少 2 像素。極小圖片可能沒有足夠內部網格節點產生變形。
- 進行中筆畫另保留一份取消快照；已提交的復原／重做快照合計最多 32 MiB，超額時移除最舊紀錄。
- 介面的記憶體數字只計原圖、輸出 RGBA 與網格陣列，**不是整個瀏覽器的記憶體上限**。原圖尺寸限制在解碼後檢查，瀏覽器解碼高解析圖片的短暫記憶體可能更高。
- 已實測 macOS 的 Chromium；Windows、Safari、實體觸控與壓感筆尚未實機驗證。

## 算法與函式

| 函式 | 作法與目的 |
| --- | --- |
| `LiquifyMesh.beginStroke / moveStroke / endStroke` | 以半徑的 8% 固定弧長分段，結束時補上剩餘距離，降低結果對指標事件密度的依賴。 |
| `LiquifyMesh.dab` | 用有限支撐核 `(1-t)^4 × (1+4t)` 平滑衰減；推移合成逆向映射 `M_new(p) = M_old(p − wΔ)`，讓既有扭曲隨筆刷繼續移動。 |
| `LiquifyMesh.validCandidate` | 對受影響網格與相鄰格的四角檢查正規化 Jacobian，門檻 0.05；不足時減半增量，最多嘗試 10 次後拒絕該步。末端不足完整網格的格子使用實際寬高。 |
| `LiquifyMesh.read / sample` | 以雙線性內插查詢逆向位移；預設網格間距 4 px、兩個 Float32 位移通道。 |
| `LiquifyMesh.cancelStroke / undo / redo` | 保存網格而非整張影像；取消筆畫不裁剪原有復原／重做紀錄。 |
| `renderWarp` | 每次從不可變原圖取樣，避免反覆對前一張結果內插造成累積模糊；在線性 sRGB、預乘 Alpha 空間做雙線性取樣，防止透明像素隱藏顏色滲入邊緣。 |
| `renderWarp` 的 tile 掃描 | 以 32 px 區塊跳過完全無位移區域，包含內插所需的相鄰節點。輸出仍先複製原圖，確保未變形像素逐位元組一致。 |
| `app.mjs` 的 `scheduleDraw / draw` | 合併一個畫面更新週期內的重繪；幾何映射沒有改變時沿用既有結果。 |

算法採通用幾何處理，沒有針對特定人臉或照片的特殊分支。這是自有實驗實作，並非 Adobe 內部算法。

## Smoke 測試

算法 Smoke 只需要 Node.js：

```sh
node experiments/Liquify/smoke.mjs
```

介面 Smoke 需 Playwright 與其 Chromium。先啟動前述本機服務，再執行：

```sh
node experiments/Liquify/browser-smoke.mjs http://127.0.0.1:8766/ build/liquify-smoke
```

如果 Playwright 不在 Node 的模組搜尋路徑，可設定 `PLAYWRIGHT_MODULE` 指向已安裝套件的 `index.js`。測試執行時不會自動安裝套件、下載瀏覽器或連接外部網站。

2026-10-04 驗證結果：

- Node.js v26.6.0：**16／16 通過**。涵蓋 identity、局部方向／影響範圍、事件分段一致性、Undo／Redo／取消、局部還原、線性光、透明度、邊界、極端筆畫、無效輸入與記憶體上限。
- macOS Chromium 151.0.7922.34：**17／17 通過**。透過實際滑鼠、鍵盤與下載事件驗證操作，並確認 PNG 重新載入後畫布逐像素相同。
- 額外算法審查：22 組尺寸／網格設定，tile 優化前後輸出逐位元組一致。
- 小型歷史壓力測試峰值 277,200 bytes，符合該測例的精確陣列上限；此數值不是一般照片或瀏覽器總用量。
- 2048×1536 遠距兩個小筆畫的局部渲染診斷，21 次暖機後測量中位數由 26.616 ms 降至 2.101 ms，持有網格陣列用量不變。此結果只適用於該測例與本機環境，不代表整體互動延遲或所有照片的加速比例。

本次完整證據位於專案的 `build/liquify-smoke-20261004/`：算法報告、瀏覽器報告、審查數據、前後截圖與實際下載的 PNG。`build/` 為本機產物，不納入正式 App。

## 參考資料

- [Adobe：液化扭曲工具與操作](https://helpx.adobe.com/photoshop/desktop/effects-filters/artistic-stylize-filters/use-liquify-to-distort-an-image.html)
- [Adobe：重建液化變形](https://helpx.adobe.com/photoshop/desktop/effects-filters/artistic-stylize-filters/reconstruct-distortions.html)
- [OpenCV：影像幾何變換與逆向取樣](https://docs.opencv.org/4.13.0/da/d54/group__imgproc__transform.html)
