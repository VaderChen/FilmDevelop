[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/FilmDevelop-1.26.1003-build1503-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/FilmDevelop-1.26.1003-build1503-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/FilmYourPhoto-1.26.1003-build-1503-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/SHA256SUMS.txt)

## 繁體中文

此發布說明已合併 **1.26.1003 build 1300**, **1.26.1003 build 1109**, **1.26.1003 build 1026**, **1.26.1003 build 0924**, **1.26.1003 build 0018**, **1.26.1002 build 2330** 的更新，以下按版本列出差異。

### 本版更新

相較版本：**1.26.1003 build 1300**。

- **改善**：最佳化配方編輯、驗證與自訂底片預設，減少重複 JSON 解碼、複製及記憶體配置，保留既有功能、畫面與操作流程。
- **改善**：遮罩資產改用最多 64 KiB 的串流緩衝區完成驗證與重複匯入比對；保留完整內容、尺寸及 SHA-256 檢查。
- **改善**：模型配對每個候選只評分一次，照片自然排序每個檔案只建立一次排序鍵；維持原配對判斷、同分處理、順序及縮圖識別。
- **改善**：最佳化 CPU Gaussian 取樣，維持原有浮點精度、權重及累加順序；macOS 與 Windows 各通過 114 組逐位元對照，Windows CPU／Vulkan 各 10 份匯出與 build 1300 完全相同。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

### 合併自 1.26.1003 build 1300

相較版本：**1.26.1003 build 1109**。

- **修正**：修正外接磁碟 JPEG 匯出失敗，恢復單張與 MCP 顯影對話框、複選匯出張數與階段進度，確認取代後繼續保護來源照片。
- **修正**：第二輪修正 12 項 Swift 移植缺漏：底片重選、重設歷史、預覽重試、修復取消、直式裁切標籤、提示詞語言、PNG 8-bit 預設、自訂底片的儲存／複製／刪除／匯出，以及 RAW 切換失敗還原。
- **修正**：保留上一輪 13 項修正，包含 AI 七階段與取消、遮罩有效性、MCP 匯出設定、完整複選重設、照片副本定位與原生拖放。
- **修正 · Windows**：Windows 下載格式與本機模型選單隱藏 MLX，預設使用 GGUF；後端拒絕不支援平台的 MLX 下載，已下載檔案保留並顯示相容性說明。 同一目錄中的具名 mmproj 可正確配對；不猜測同分或不明確的組合。
- **改善**：減少狀態快照與復原歷史的重複配置，共用不可變影像字串與修復資料，清空淘汰紀錄參照；保持既有照片處理及介面版型。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

### 合併自 1.26.1003 build 1109

相較版本：**1.26.1003 build 1026**。

- **修正**：修正舊 FilmYourPhoto 首次移轉時長時間沒有提示：啟動即顯示等待對話框，列出設定、舊照片紀錄、目錄掃描與調整移轉階段；已知總量時顯示實際處理數與進度條，完成後自動解除等待。原始照片與舊版資料保留。
- **修正**：修正更新下載同時出現「取消」與「取消下載」，以及資訊視窗同時出現「取消」與「關閉」；共用對話框已有取消或關閉操作時，不再追加重複按鈕。
- **修正**：補齊共用對話框的四語標題、說明、按鈕與進度文字；「關閉視窗」與開關的 Off 分開處理，檔名、模型名稱及使用者輸入保留原文。
- **修正**：名稱輸入為空白時停用確認，Enter 也不會送出；對話框的鍵盤事件不再傳到背景裁切、修復與原圖比較，關閉後可恢復原控制項的焦點。
- **改善**：提示詞編輯改用原生模態對話框，避免焦點移到背景；介面狀態更新保留草稿，取消後回到原本的編輯入口。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1026...v1.26.1003-build-1109) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/desktop/RESTORATION.md)

### 合併自 1.26.1003 build 1026

相較版本：**1.26.1003 build 0924**。

- **新增**：目前照片需要另外安裝 Adobe DNG Converter 時，自動顯示確認對話框；確認後才用系統預設瀏覽器開啟 Adobe 官方下載頁，取代上一版僅提供照片下方入口的方式。
- **改善**：取消解碼器確認後保留畫面，同一張照片重試不反覆彈出；可從下方入口重新開啟。提示會等待其他對話框結束，忽略過期照片與無關錯誤，並提供四語說明。
- **修正**：更新下載視窗補上進度條，從 0% 起與百分比及容量同步，驗證安裝包時維持滿格；取消會清理暫存，舊下載事件不會影響新的對話框。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0924...v1.26.1003-build-1026) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1026/desktop/RESTORATION.md)

### 合併自 1.26.1003 build 0924

相較版本：**1.26.1003 build 0018**。

- **修正**：補上 Nikon HE／HE* NEF 與 GoPro GPR 的共同解碼流程：系統或 LibRaw 缺少解碼器時，使用已安裝的 Adobe DNG Converter 建立無損 RAW 快取，支援 Mac 與 Windows。
- **新增**：缺少補充解碼器時，在照片下方提供 Adobe 官方下載與重新偵測入口；使用者需自行完成原廠安裝。FilmDevelop 不內附 Adobe Converter，一般預覽不自動跳出安裝對話框。
- **修正**：GPR 加入照片匯入及兩平台 RAW 辨識；沒有可用內嵌縮圖時也能補充解碼，安裝後重新偵測可恢復列表縮圖。
- **改善**：補充解碼保留原始照片、調整識別與拍攝 EXIF；快取有內容驗證、容量上限、取消與結束清理。完整感光資料仍由共用 LibRaw 顯影，不以相機 JPEG 取代編輯來源。
- **改善**：補驗 Mac 47 張 RAW 的 141 次預覽／匯出、Windows 20 張的 60 次工作及預設系統模式 42 次工作；公開 EXIF、尺寸及像素差異紀錄。未知格式、JPEG XL／Enhanced DNG 與逐像素一致性仍有限制。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

### 合併自 1.26.1003 build 0018

相較版本：**1.26.1002 build 2330**。

- **修正**：更新完成視窗改為顯示本次新增、修正與改善，列出比較版本，並依介面語言顯示繁中、英文、日文或韓文。
- **修正**：跨版本升級會分版列出尚未看過的更新；其他對話框關閉後會再次顯示摘要，避免更新說明被略過。
- **改善 · Windows**：Windows 免安裝 ZIP 縮減 C++ 除錯資料，保留原有影像演算、查表、模型與 Microsoft Runtime。
- **新增**：新增逐版更新紀錄；README、程式摘要與 GitHub Release 使用同一份四語資料，並補列 build 2330 相較 build 1323 的差異。
- **改善**：完整發布流程先清空專案 dist，再依序建置 Mac 與 Windows；驗證版本紀錄與成品清單，避免混入舊版封裝。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

### 合併自 1.26.1002 build 2330

相較版本：**1.26.1002 build 1323**。

- **修正**：統一列表縮圖、編輯縮圖與完整預覽的顯示範圍，修正切換照片時過渡畫面突然放大的問題。
- **改善**：重用有容量上限的快取與 C++ 工作執行緒；Mac 軟體 RAW 編輯預覽採半尺寸解碼，完整預覽與匯出維持完整解碼。
- **改善**：共用乳劑晶體計算並對邊界重新計算，維持四樣本、三層與 FP32；指定量測的乳劑階段約快 30–35%，不代表整體預覽等幅加速。
- **新增 · Windows**：Windows 改為免安裝 ZIP，完整解壓即可執行，內附 12 個 Microsoft 原廠 VC++ x64 Runtime DLL；仍需要 WebView2。
- **新增 · Windows**：Windows 免安裝版可在程式內更新，檢查 ZIP 與逐檔 SHA-256，保留額外檔案並於啟動失敗時還原；舊 setup 版首次轉移需手動下載 ZIP。
- **修正**：修正 Swift Sendable 警告與建置系統相容性，並補驗 Windows CPU／Vulkan 影像與更新流程。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)

## English

These release notes include the changes from **1.26.1003 build 1300**, **1.26.1003 build 1109**, **1.26.1003 build 1026**, **1.26.1003 build 0924**, **1.26.1003 build 0018**, **1.26.1002 build 2330**, grouped by version below.

### Changes in this release

Compared with: **1.26.1003 build 1300**。

- **Improved**：Optimize recipe editing, validation and custom-film defaults by reducing repeated JSON decoding, copying and allocations, preserving features, layout and workflow.
- **Improved**：Validate mask assets and compare existing imports with a streaming buffer capped at 64 KiB, retaining full content, dimensions and SHA-256 checks.
- **Improved**：Score each model-pairing candidate once and build natural-sort keys once per photo, retaining pairing decisions, tie handling, ordering and thumbnail identities.
- **Improved**：Optimize CPU Gaussian sampling while preserving floating-point precision, weights and accumulation order. All 114 bit-exact cases pass on both macOS and Windows; 10 exports per Windows CPU/Vulkan backend match build 1300 byte for byte.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

### Included from 1.26.1003 build 1300

Compared with: **1.26.1003 build 1109**。

- **Fixed**：Fix external-volume JPEG export failures and restore single-image and MCP development dialogs, batch counts and stage progress while protecting source photos.
- **Fixed**：Fix 12 additional Swift migration gaps in preset reselection, reset history, preview retry, repair cancellation, portrait crop labels, prompt language, the 8-bit PNG default, custom-film save/copy/delete/export, and RAW-switch rollback.
- **Fixed**：Retain the previous 13 fixes, including seven-stage AI progress and cancellation, mask validity, MCP export settings, multi-photo reset, duplicate selection and native drag-and-drop.
- **Fixed · Windows**：Hide MLX from Windows download and local-model selectors and default to GGUF. Reject unsupported MLX downloads; retain existing files with a compatibility explanation. Match named mmproj files in shared directories and reject ambiguous pairs.
- **Improved**：Reduce allocations in state snapshots and edit history by sharing immutable image and repair data and releasing evicted references, preserving image processing and interface layout.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

### Included from 1.26.1003 build 1109

Compared with: **1.26.1003 build 1026**。

- **Fixed**：Fixed the silent wait when migrating from FilmYourPhoto. A startup dialog shows settings, legacy records, folder scanning and photo-adjustment stages, with actual item counts and a progress bar when totals are known. It closes automatically when ready, preserving original photos and legacy data.
- **Fixed**：Fixed duplicate Cancel and Cancel download buttons in update downloads, and duplicate Cancel and Close actions in information dialogs. Shared dialogs no longer add a fallback Cancel when a dismiss action is already provided.
- **Fixed**：Completed four-language titles, descriptions, buttons, and progress messages for shared dialogs. Closing a window is distinguished from the Off setting; filenames, model names, and user input remain unchanged.
- **Fixed**：Blank names cannot be submitted by the confirmation button or Enter. Dialog key events no longer reach background crop, repair, and original-comparison controls, and focus returns to the original control when it remains available.
- **Improved**：Prompt editing now uses a native modal dialog to keep focus out of the background. UI state refreshes preserve the draft, and cancelling returns focus to the original edit control.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1026...v1.26.1003-build-1109) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/desktop/RESTORATION.md)

### Included from 1.26.1003 build 1026

Compared with: **1.26.1003 build 0924**。

- **Added**：When the current photo requires a separately installed Adobe DNG Converter, a confirmation dialog now appears automatically. Confirming opens Adobe’s official download page in the system default browser, replacing the previous footer-only prompt.
- **Improved**：Cancelling preserves the current view and does not repeatedly prompt when retrying the same photo. The footer can reopen the dialog. Prompts wait for other dialogs, ignore stale photos and unrelated errors, and include all four interface languages.
- **Fixed**：The update download dialog now includes a progress bar synchronized with percentage and size from 0%, staying full during package verification. Cancellation clears temporary files, and stale download events cannot affect a newer dialog.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0924...v1.26.1003-build-1026) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1026/desktop/RESTORATION.md)

### Included from 1.26.1003 build 0924

Compared with: **1.26.1003 build 0018**。

- **Fixed**：Added a shared decoding fallback for Nikon HE/HE* NEF and GoPro GPR on Mac and Windows. When the system or LibRaw lacks a decoder, an installed Adobe DNG Converter creates a lossless RAW cache.
- **Added**：When the additional decoder is missing, the photo footer offers Adobe’s official download page and a check-again action. Users complete Adobe’s installation themselves. FilmDevelop does not bundle the converter or automatically open an installation dialog during preview.
- **Fixed**：GPR is now recognized by photo import and both RAW engines. Files without a usable embedded thumbnail can use the supplemental decoder, and checking again after installation restores failed list thumbnails.
- **Improved**：Supplemental decoding preserves original photos, edit identities and capture EXIF. The cache validates content, has a size limit, supports cancellation and is removed on exit. Shared LibRaw still develops the full sensor data; camera JPEGs are not used as editing sources.
- **Improved**：Validated 141 preview/export operations across 47 RAW files on Mac, 60 operations across 20 files on Windows, and 42 Windows System-mode operations. EXIF, dimensions and pixel differences are documented; unknown formats, JPEG XL/Enhanced DNG and pixel identity remain limited.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

### Included from 1.26.1003 build 0018

Compared with: **1.26.1002 build 2330**。

- **Fixed**：The update-complete dialog now lists actual additions, fixes and improvements, with a comparison version, in the selected interface language.
- **Fixed**：When skipping versions, changes are grouped by release. If another dialog is open, the update summary is delivered again after it closes.
- **Improved · Windows**：The Windows portable ZIP omits C++ debug data while retaining the existing image algorithms, lookup tables, models and Microsoft runtime.
- **Added**：Added a version-by-version changelog. README summaries, in-app notes and GitHub releases share one four-language source, including the changes from build 1323 to build 2330.
- **Improved**：The full release workflow clears the project dist directory once before building Mac and Windows in sequence, and validates release notes and the artifact list.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

### Included from 1.26.1002 build 2330

Compared with: **1.26.1002 build 1323**。

- **Fixed**：Aligned framing across list thumbnails, editing thumbnails and full previews to prevent a sudden zoom during photo transitions.
- **Improved**：Reused bounded caches and C++ worker threads. Mac software RAW editing previews use half-size decoding, while full-resolution previews and exports retain full decoding.
- **Improved**：Shared emulsion-crystal calculations with boundary recalculation, retaining four samples, three layers and FP32. The measured emulsion stage is about 30–35% faster; this is not an end-to-end preview speedup.
- **Added · Windows**：Windows now ships as a portable ZIP: extract all files and run. It includes 12 original Microsoft VC++ x64 runtime DLLs; WebView2 is still required.
- **Added · Windows**：The Windows portable app can update in place, verifying ZIP and per-file SHA-256, preserving additional files and rolling back on startup failure. Existing setup users must manually download the ZIP for the first transition.
- **Fixed**：Fixed Swift Sendable warnings and build-system compatibility, and extended Windows CPU/Vulkan image and update validation.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)

## 日本語

このリリースノートには **1.26.1003 build 1300**, **1.26.1003 build 1109**, **1.26.1003 build 1026**, **1.26.1003 build 0924**, **1.26.1003 build 0018**, **1.26.1002 build 2330** の更新内容を統合し、以下にバージョン別の差分を記載しています。

### 今回の更新

比較元：**1.26.1003 build 1300**。

- **改善**：配方編集・検証とカスタムフィルムの初期値を最適化し、JSON の重複デコード、コピー、メモリ割り当てを削減。既存機能、画面、操作手順を維持します。
- **改善**：マスク資産の検証と既存データとの照合を最大 64 KiB のストリームバッファで実行。全内容、寸法、SHA-256 の検証を維持します。
- **改善**：モデル対応候補の評価と写真の自然順ソートキーの生成を各 1 回に削減。対応判定、同点処理、並び順、サムネイル識別を維持します。
- **改善**：CPU Gaussian のサンプリングを最適化し、浮動小数点精度、重み、加算順序を維持。macOS・Windows で各 114 件のビット単位比較に合格し、Windows CPU／Vulkan 各 10 件の書き出しが build 1300 と完全一致。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

### 1.26.1003 build 1300 から統合した変更

比較元：**1.26.1003 build 1109**。

- **修正**：外部ドライブの JPEG 書き出し失敗を修正。単一画像と MCP の現像表示、一括処理の枚数と進捗を復元し、元画像を保護します。
- **修正**：フィルム再選択、リセット履歴、プレビュー再試行、修復キャンセル、縦写真の比率、プロンプト言語、PNG 8-bit 既定値、カスタムフィルム操作、RAW 切替失敗時の復元など、追加の移植漏れ 12 件を修正。
- **修正**：前回の修正 13 件を維持。AI の 7 段階表示とキャンセル、マスク検証、MCP 書き出し設定、複数写真のリセット、複製選択、ドラッグ読込を含みます。
- **修正 · Windows**：Windows のダウンロード形式とローカルモデル選択から MLX を非表示にし、GGUF を既定に変更。非対応 MLX のダウンロードを拒否し、既存ファイルは説明とともに保持します。 同じフォルダ内の型名付き mmproj を正しく対応付け、曖昧な組み合わせは拒否します。
- **改善**：不変の画像・修復データの共有と破棄した履歴の参照解放により、状態と履歴のメモリ割り当てを削減。画像処理と画面構成は維持します。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

### 1.26.1003 build 1109 から統合した変更

比較元：**1.26.1003 build 1026**。

- **修正**：FilmYourPhoto からの初回移行中に案内が出ない問題を修正。起動時のダイアログに設定、旧写真記録、フォルダ確認、写真調整の移行段階を表示し、総数が分かる処理では実際の件数と進捗バーを表示します。完了後に自動で閉じ、元の写真と旧データを保持します。
- **修正**：更新ダウンロードで「キャンセル」と「ダウンロードをキャンセル」、情報画面で「キャンセル」と「閉じる」が重複する問題を修正。キャンセルまたは閉じる操作が既にある場合、共通ダイアログは追加ボタンを表示しません。
- **修正**：共通ダイアログのタイトル、説明、ボタン、進捗メッセージを4言語に対応。「閉じる」と設定の「オフ」を区別し、ファイル名、モデル名、入力内容は原文を保持します。
- **修正**：名前が空白の場合は確認ボタンと Enter による送信を無効化。ダイアログのキー操作が背後のトリミング、修復、元画像比較に伝わらず、閉じた後は元の操作対象が残っていればフォーカスを戻します。
- **改善**：プロンプト編集をネイティブのモーダルダイアログに変更し、背後へのフォーカス移動を防止。画面状態の更新でも下書きを保持し、キャンセル後は元の編集ボタンに戻ります。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1026...v1.26.1003-build-1109) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/desktop/RESTORATION.md)

### 1.26.1003 build 1026 から統合した変更

比較元：**1.26.1003 build 0924**。

- **追加**：現在の写真に Adobe DNG Converter の別途インストールが必要な場合、確認ダイアログを自動表示します。確認後に既定のブラウザーで Adobe 公式ダウンロードページを開きます。前版の写真下部だけの案内から変更しました。
- **改善**：キャンセル後も画面を保持し、同じ写真の再試行では繰り返し表示しません。写真下部から再度開けます。他のダイアログが終了するまで待機し、古い写真や無関係なエラーは対象外とし、4 言語で案内します。
- **修正**：更新ダウンロード画面に進捗バーを追加し、0% から割合と容量に同期します。パッケージ検証中は満了表示を維持。キャンセル時は一時ファイルを削除し、古いダウンロード通知が新しいダイアログに影響しないようにします。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0924...v1.26.1003-build-1026) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1026/desktop/RESTORATION.md)

### 1.26.1003 build 0924 から統合した変更

比較元：**1.26.1003 build 0018**。

- **修正**：Mac と Windows に Nikon HE／HE* NEF と GoPro GPR の共通代替デコード経路を追加。システムや LibRaw にデコーダーがない場合、インストール済みの Adobe DNG Converter でロスレス RAW キャッシュを作成します。
- **追加**：追加デコーダーがない場合は写真の下部に Adobe 公式ダウンロードと再検出の操作を表示します。Adobe のインストールは利用者が完了してください。Converter は同梱せず、通常のプレビュー中にインストール画面を自動表示しません。
- **修正**：GPR を写真読み込みと両プラットフォームの RAW 判定に追加。利用可能な埋め込みサムネイルがない場合も追加デコードを利用でき、インストール後の再検出で一覧サムネイルを再試行します。
- **改善**：追加デコードでは元写真、編集の識別情報、撮影 EXIF を保持します。キャッシュは内容検証、容量制限、キャンセル、終了時の削除に対応。共通 LibRaw が全画素のセンサーデータを現像し、カメラ内 JPEG を編集元にしません。
- **改善**：Mac の RAW 47 ファイルでプレビュー・書き出し 141 回、Windows の 20 ファイルで 60 回、システム設定で 42 回を検証。EXIF、寸法、画素差を記録しました。未知の形式、JPEG XL／Enhanced DNG、画素単位の一致には制限が残ります。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

### 1.26.1003 build 0018 から統合した変更

比較元：**1.26.1002 build 2330**。

- **修正**：更新完了画面に今回の追加・修正・改善と比較元バージョンを表示し、選択した表示言語に合わせます。
- **修正**：複数バージョンを飛ばして更新した場合は変更をバージョン別に表示します。他のダイアログが開いていても、閉じた後に更新内容を表示します。
- **改善 · Windows**：Windows ポータブル ZIP から C++ のデバッグ情報を除き、画像処理、ルックアップテーブル、モデル、Microsoft Runtime は維持します。
- **追加**：バージョン別の変更履歴を追加。README、アプリ内の更新内容、GitHub Release は同じ4言語データを使用し、build 1323 から build 2330 への変更も記載します。
- **改善**：完全なリリース処理では最初にプロジェクトの dist を一度空にしてから Mac と Windows を順にビルドし、変更履歴と成果物一覧を検証します。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

### 1.26.1002 build 2330 から統合した変更

比較元：**1.26.1002 build 1323**。

- **修正**：一覧サムネイル、編集サムネイル、完全プレビューの表示範囲を統一し、写真切り替え時に突然拡大する問題を修正しました。
- **改善**：容量制限付きキャッシュと C++ ワーカースレッドを再利用。Mac のソフトウェア RAW 編集プレビューは半解像度でデコードし、原寸プレビューと書き出しは完全デコードを維持します。
- **改善**：乳剤結晶の計算を共有し、境界を再計算。4サンプル・3層・FP32 を維持し、指定条件の乳剤段階は約30～35%高速化しました。プレビュー全体の高速化率ではありません。
- **追加 · Windows**：Windows をポータブル ZIP に変更。全ファイルを展開して実行できます。Microsoft 純正 VC++ x64 Runtime DLL を12個同梱し、WebView2 は引き続き必要です。
- **追加 · Windows**：Windows ポータブル版はアプリ内更新に対応。ZIP と各ファイルの SHA-256 を検証し、追加ファイルを保持し、起動失敗時は復元します。旧 setup 版からの初回移行は ZIP の手動取得が必要です。
- **修正**：Swift の Sendable 警告とビルドシステム互換性を修正し、Windows CPU／Vulkan の画像と更新処理を追加検証しました。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)

## 한국어

이 릴리스 노트는 **1.26.1003 build 1300**, **1.26.1003 build 1109**, **1.26.1003 build 1026**, **1.26.1003 build 0924**, **1.26.1003 build 0018**, **1.26.1002 build 2330**의 변경 사항을 통합하며, 아래에 버전별 차이를 표시합니다.

### 이번 릴리스의 변경 사항

비교 버전: **1.26.1003 build 1300**。

- **개선**：레시피 편집·검증과 사용자 필름 기본값을 최적화하여 반복 JSON 디코딩, 복사 및 메모리 할당을 줄입니다. 기존 기능, 화면과 작업 흐름은 유지합니다.
- **개선**：최대 64 KiB의 스트리밍 버퍼로 마스크 자산을 검증하고 기존 가져오기와 비교합니다. 전체 내용, 크기 및 SHA-256 검사는 유지합니다.
- **개선**：모델 연결 후보 평가는 후보당 한 번, 사진의 자연 정렬 키 생성은 파일당 한 번만 수행합니다. 연결 판단, 동점 처리, 순서와 썸네일 식별은 유지합니다.
- **개선**：CPU Gaussian 샘플링을 최적화하며 부동소수점 정밀도, 가중치와 누적 순서를 유지합니다. macOS와 Windows 각각 114건의 비트 단위 비교를 통과했으며 Windows CPU/Vulkan별 내보내기 10건이 build 1300과 완전히 일치합니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

### 1.26.1003 build 1300에서 통합한 변경 사항

비교 버전: **1.26.1003 build 1109**。

- **수정**：외장 드라이브의 JPEG 내보내기 실패를 수정하고 단일 이미지와 MCP 현상 창, 일괄 작업 장수와 진행률을 복원하며 원본 사진을 보호합니다.
- **수정**：필름 재선택, 초기화 기록, 미리보기 재시도, 복구 취소, 세로 사진 비율, 프롬프트 언어, PNG 8-bit 기본값, 사용자 필름 작업 및 RAW 전환 실패 복원 등 추가 이식 누락 12건을 수정했습니다.
- **수정**：AI 7단계 진행률과 취소, 마스크 검증, MCP 내보내기 설정, 다중 사진 초기화, 복사본 선택 및 드래그 열기 등 이전 수정 13건을 유지합니다.
- **수정 · Windows**：Windows 다운로드 형식과 로컬 모델 선택에서 MLX를 숨기고 GGUF를 기본값으로 사용합니다. 지원하지 않는 MLX 다운로드를 거부하고 기존 파일은 호환성 안내와 함께 유지합니다. 같은 폴더의 모델명이 포함된 mmproj를 올바르게 연결하고 모호한 조합은 거부합니다.
- **개선**：불변 이미지와 복구 데이터를 공유하고 제거된 기록의 참조를 해제하여 상태와 편집 기록의 메모리 할당을 줄입니다. 이미지 처리와 화면 구성은 유지합니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

### 1.26.1003 build 1109에서 통합한 변경 사항

비교 버전: **1.26.1003 build 1026**。

- **수정**：FilmYourPhoto에서 처음 이전할 때 안내 없이 기다려야 하는 문제를 수정했습니다. 시작 대화상자에 설정, 이전 사진 기록, 폴더 검색 및 사진 조정 이전 단계를 표시하고, 전체 수를 알면 실제 처리 수와 진행 표시줄을 표시합니다. 완료되면 자동으로 닫히며 원본 사진과 이전 데이터는 보존됩니다.
- **수정**：업데이트 다운로드의 취소 버튼과 정보 대화상자의 취소·닫기 버튼이 중복되는 문제를 수정했습니다. 취소 또는 닫기 동작이 이미 있으면 공통 대화상자에 취소 버튼을 추가하지 않습니다.
- **수정**：공통 대화상자의 제목, 설명, 버튼 및 진행 메시지에 네 가지 언어를 적용했습니다. 창 닫기와 설정의 꺼짐을 구분하며 파일명, 모델명 및 사용자 입력은 원문을 유지합니다.
- **수정**：이름이 비어 있으면 확인 버튼과 Enter로 제출할 수 없습니다. 대화상자 키 입력이 배경의 자르기, 복구 및 원본 비교에 전달되지 않으며, 기존 컨트롤이 남아 있으면 닫은 뒤 포커스를 복원합니다.
- **개선**：프롬프트 편집에 기본 모달 대화상자를 사용해 배경으로 포커스가 이동하지 않도록 했습니다. 화면 상태가 갱신되어도 초안을 유지하며 취소하면 기존 편집 버튼으로 돌아갑니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1026...v1.26.1003-build-1109) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/desktop/RESTORATION.md)

### 1.26.1003 build 1026에서 통합한 변경 사항

비교 버전: **1.26.1003 build 0924**。

- **추가**：현재 사진에 Adobe DNG Converter의 별도 설치가 필요하면 확인 대화상자를 자동으로 표시합니다. 확인한 뒤 시스템 기본 브라우저로 Adobe 공식 다운로드 페이지를 엽니다. 이전 버전의 사진 아래 안내만 제공하던 방식을 개선했습니다.
- **개선**：취소하면 현재 화면을 유지하며 같은 사진을 다시 시도할 때 반복해서 표시하지 않습니다. 사진 아래에서 다시 열 수 있습니다. 다른 대화상자가 닫힐 때까지 기다리고 이전 사진이나 관련 없는 오류는 제외하며 네 가지 언어로 안내합니다.
- **수정**：업데이트 다운로드 대화상자에 진행률 표시줄을 추가했습니다. 0%부터 비율과 용량에 맞춰 표시하고 패키지 검증 중에는 가득 찬 상태를 유지합니다. 취소 시 임시 파일을 정리하며 이전 다운로드 이벤트가 새 대화상자에 영향을 주지 않습니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0924...v1.26.1003-build-1026) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1026/desktop/RESTORATION.md)

### 1.26.1003 build 0924에서 통합한 변경 사항

비교 버전: **1.26.1003 build 0018**。

- **수정**：Mac과 Windows에 Nikon HE/HE* NEF 및 GoPro GPR의 공통 대체 디코딩 경로를 추가했습니다. 시스템이나 LibRaw에 디코더가 없으면 설치된 Adobe DNG Converter로 무손실 RAW 캐시를 만듭니다.
- **추가**：추가 디코더가 없으면 사진 아래에 Adobe 공식 다운로드와 다시 검색 기능을 표시합니다. Adobe 설치는 사용자가 직접 완료해야 합니다. Converter는 포함하지 않으며 일반 미리보기에서 설치 대화상자를 자동으로 열지 않습니다.
- **수정**：사진 가져오기와 두 플랫폼의 RAW 인식에 GPR을 추가했습니다. 사용할 수 있는 내장 썸네일이 없어도 추가 디코딩을 사용하며 설치 후 다시 검색하면 실패한 목록 썸네일을 다시 불러옵니다.
- **개선**：추가 디코딩은 원본 사진, 편집 식별 정보와 촬영 EXIF를 보존합니다. 캐시는 내용 검사, 용량 제한, 취소와 종료 시 정리를 지원합니다. 공통 LibRaw가 전체 센서 데이터를 현상하며 카메라 JPEG를 편집 원본으로 사용하지 않습니다.
- **개선**：Mac RAW 47개에서 미리보기·내보내기 141회, Windows 20개에서 60회 및 시스템 모드 42회를 검증했습니다. EXIF, 크기와 픽셀 차이를 기록했습니다. 알 수 없는 형식, JPEG XL/Enhanced DNG와 픽셀 단위 일치에는 제한이 남아 있습니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

### 1.26.1003 build 0018에서 통합한 변경 사항

비교 버전: **1.26.1002 build 2330**。

- **수정**：업데이트 완료 창에 실제 추가·수정·개선 사항과 비교 버전을 표시하고 선택한 UI 언어를 적용합니다.
- **수정**：여러 버전을 건너뛰면 변경 사항을 버전별로 표시합니다. 다른 대화상자가 열려 있으면 닫힌 후 업데이트 내용을 다시 표시합니다.
- **개선 · Windows**：Windows 포터블 ZIP에서 C++ 디버그 정보를 제거하고 기존 이미지 연산, 룩업 테이블, 모델과 Microsoft Runtime을 유지합니다.
- **추가**：버전별 변경 기록을 추가했습니다. README, 앱 내 요약과 GitHub Release가 4개 언어의 공통 데이터를 사용하며 build 1323 대비 build 2330의 차이도 기록합니다.
- **개선**：전체 릴리스 작업은 프로젝트의 dist를 먼저 한 번 비운 후 Mac과 Windows를 순서대로 빌드하고 버전 기록과 배포 파일 목록을 검증합니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

### 1.26.1002 build 2330에서 통합한 변경 사항

비교 버전: **1.26.1002 build 1323**。

- **수정**：목록 썸네일, 편집 썸네일과 전체 미리보기의 표시 범위를 맞춰 사진 전환 중 갑자기 확대되는 문제를 수정했습니다.
- **개선**：용량이 제한된 캐시와 C++ 작업 스레드를 재사용합니다. Mac 소프트웨어 RAW 편집 미리보기는 절반 크기로 디코딩하며 전체 해상도 미리보기와 내보내기는 전체 디코딩을 유지합니다.
- **개선**：유제 결정 계산을 공유하고 경계를 다시 계산하며 4개 샘플·3개 층·FP32를 유지합니다. 지정 조건의 유제 단계는 약 30–35% 빨라졌으며 전체 미리보기의 개선율은 아닙니다.
- **추가 · Windows**：Windows를 포터블 ZIP으로 배포하여 전체 압축 해제 후 실행할 수 있습니다. Microsoft 원본 VC++ x64 Runtime DLL 12개를 포함하며 WebView2는 여전히 필요합니다.
- **추가 · Windows**：Windows 포터블 앱에서 ZIP·개별 파일의 SHA-256을 검증하고 추가 파일을 유지하며 시작 실패 시 복구하는 업데이트를 지원합니다. 기존 setup 사용자의 첫 전환은 ZIP 수동 다운로드가 필요합니다.
- **수정**：Swift Sendable 경고와 빌드 시스템 호환성을 수정하고 Windows CPU/Vulkan 이미지 및 업데이트 검증을 보강했습니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)
