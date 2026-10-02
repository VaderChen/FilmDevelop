[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS — Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/FilmDevelop-1.26.1002-build1323-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/FilmDevelop-1.26.1002-build1323-windows-x64-setup.exe) · [macOS — Swift upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/FilmYourPhoto-1.26.1002-build-1323-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/SHA256SUMS.txt)

## 繁體中文

本次將桌面主程序與共用功能改為 Go／Wails，macOS 影像與硬體計算由 Swift／C++ 處理，新增 Windows x64 Beta。以下為相較上一版 v1.26.0930-build-1745 的主要變更。

### 主要變更

- 清除 Go／Swift／C++ 產物中的私人建置路徑，改用相對來源路徑；封裝前檢查私人路徑、私鑰與常見權杖格式。本機 pack.command 不納入 Git 或發布檔。
- 修正舊 Swift 版無法更新，並加入一次性安裝識別移轉。FilmYourPhoto 過渡包內含已簽章、公證的標準 App，首次啟動於原位置轉為 FilmDevelop，不需再次下載；後續更新只使用標準包。保留雜湊、架構、簽章及相同 Developer Team 檢查。
- 縮減封裝：Mac 排除 Windows 專用色彩／編輯查表，Core ML 只保留編譯後的執行模型；兩平台 Go 正式程式移除除錯符號。RAW 校色資料及所有功能保留。
- 兩平台共用底片、照片管理、調整、裁切、修復、AI 模型、MCP、更新與匯出流程。
- Windows 依實際能力偵測 RAW 解碼器與 Vulkan GPU；優先使用可用 GPU，失敗時回退 CPU。選項持久化保存，重啟時重新核對。
- 預覽先顯示列表縮圖，再漸進顯露套用參數的結果；重用解碼、遮罩與成品快取，改善切換照片／底片及連續調整。一般等待訊息放在照片下方，切換計算後端使用動畫對話框。
- 修正已編輯照片未還原參數；沿用舊 Swift 星級、分類、自訂底片、提示詞、遮罩、模型配對及介面偏好。增加移轉紀錄、資料庫匯出／匯入與重新定位，新版既有資料優先。
- 裁切選單增加有分隔線的「還原」，恢復原始大小與角度；計算過程保留目前畫面。
- 匯出預設名稱與 Swift 版一致，新增預設開啟的「寫入 EXIF」。JPEG、PNG、WebP、TIFF 可保留原始拍攝資訊，PNG／TIFF 支援 8／16 bit。
- 右鍵選單改為一般操作選單；對話框按鈕同列並依確認、取消、刪除分色；設定按鈕與左側底片列表更一致、緊湊。
- 自訂底片儲存後預設勾選，修正超大縮圖偏好，移除重複名稱提示及不存在的 MCP 設定檔列。
- 保留隱藏的 GR III・晴空暖橙配方，供舊照片及自訂底片還原，並同步 Swift、Go 與 Windows 色彩資料。

### 下載與升級

- **Mac**：Apple Silicon、macOS 14 以上。DMG 與內含 App 已完成 Developer ID 簽章、Apple 公證、票證附加及 Gatekeeper 驗證。
- **Windows x64 Beta**：Windows 10／11 x64，需要 WebView2 與 VC++ x64 Runtime。安裝檔未簽 Authenticode。
- 舊 Swift Mac 版可從「檢查更新」直接升級；FilmYourPhoto 過渡入口亦適用於上一版保留舊識別的 Go 安裝。完成移轉後只使用 FilmDevelop，原資料位置不變。過渡期仍提供兩種下載，由更新器自動選擇，不需同時安裝。
- 資料移轉保留舊檔及收據，不覆寫新版已有修改。跨電腦資料包不含原始照片；只有舊雜湊而缺少來源路徑的紀錄需重新定位。

### 驗證與已知差異

- build 1323 整併上一版內容並新增完整移轉驗證：實際過渡啟動、安裝 helper 替換、標準 App 再次開啟、16 份既有資料不變、build 1243 Go 接受過渡包，以及下一版僅有標準包的選擇均通過；另通過 16 項原生與 45 項桌面 Smoke。標準 DMG 約 83.1 MiB，過渡 DMG 約 87.9 MiB。Windows 同步版本與封裝校驗，本輪未重跑實機。

- build 1243 重新驗證：精簡前後 77 組 Mac 影像像素完全相同；原生 16 項、Wails 45 項、MLX 真實推論與最終 DMG 啟動／匯出通過。舊 Swift 隔離副本完成選包、簽章準備、替換與 Go 收據確認；Windows 最新成品完成 158 檔校驗、GUI 啟動與 6 個原生函式庫載入。兩種 Mac 包各 108 檔、Windows 159 檔通過發布隱私掃描。
- build 1243 的標準 Mac DMG 約 **83.1 MiB**，相較撤回的 build 1208（221.5 MiB）減少 **62.5%**；9 月 30 日 Swift DMG 為 96.8 MiB。
- 已完成 Go race／vet、共用契約與資料檢查、Mac 原生及實際 Wails Smoke，以及 Windows 交叉編譯與封裝檢查。前輪 Windows 10／GTX 1060 實機涵蓋配方、編輯、匯出、資料移轉、GGUF 與 ONNX 修復；兩平台 CPU／GPU 共 1,216 組 Swift 影像參考比較通過。
- build 1208 發布整理曾補測本機 C++ CPU／GPU 各 289 組；Windows 10 實機完成 158 個 payload 檔案校驗、正式 GUI 啟動、10 項 WebView2 操作、3 項設定重開及 CPU／GPU 各 16 組比較。完整 NSIS 解壓校驗 159 檔（含清單本身），此次未在正式安裝位置重跑安裝／解除安裝。
- 44 份 RAW 樣本中，共用 LibRaw 成功解碼 38 份，其中 37 份通過嚴格跨平台數值比較。Nikon HE／HE*、GoPro GPR 仍有缺口；原生 RAW、主體／深度、降噪、景深與日期字形仍有平台差異。
- 既有 Swift XCTest 的 10 個案例／20 個失敗斷言維持原基線。Windows 11、乾淨電腦缺少 Runtime 與其他 GPU 驅動仍需擴大驗證。

[功能恢復紀錄（繁體中文）](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md) · [發布驗證摘要](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/release-validation.json)

## English

The desktop host and shared features now use Go/Wails, with Swift/C++ handling image processing and hardware computation on macOS. This release adds Windows x64 Beta. The changes below are relative to v1.26.0930-build-1745.

### What changed

- Removed private build paths from Go/Swift/C++ artifacts in favor of relative source paths. Packaging checks for private paths, private keys and common token formats. The local pack.command is excluded from Git and release packages.
- Fixed updates from the old Swift app and added a one-time installation identity migration. The FilmYourPhoto bridge includes the signed, notarized standard app and replaces itself in place on first launch without another download. Future updates use FilmDevelop. Hash, architecture, signature and matching Developer Team checks remain enforced.
- Reduced package size: Mac excludes Windows-only color/editing lookup tables and includes only compiled Core ML models. Production Go binaries on both platforms omit debug symbols. RAW color mappings and all features are retained.
- Both platforms share workflows for film presets, photo management, adjustments, cropping, repair, AI models, MCP, updates and export.
- Windows detects available RAW decoders and Vulkan GPUs, prefers a usable GPU and falls back to the CPU on failure. Preferences persist and are checked again at startup.
- Previews start with the photo list thumbnail, then progressively reveal the adjusted result. Reusing decoded images, masks and rendered results improves photo/preset switching and continuous adjustments. Routine progress appears below the image; switching compute backends uses an animated dialog.
- Fixed edited photos failing to restore adjustments. Ratings, categories, custom films, prompts, masks, model mappings and interface preferences migrate from the Swift version. Added migration records, database export/import and path relocation, preserving existing edits in the new version.
- Added a separated Restore item at the end of the crop menu to reset original size and rotation. The current image stays visible during processing.
- Default export names now match the Swift version. Write EXIF is enabled by default; JPEG, PNG, WebP and TIFF can retain original capture metadata. PNG/TIFF support 8/16-bit output.
- Replaced the unusual context menu with a conventional menu. Dialog actions share one row and use distinct colors for confirmation, cancellation and deletion. Settings buttons and the film sidebar are more consistent and compact.
- Newly saved custom films are selected by default. Fixed the extra-large thumbnail preference and removed redundant name tooltips and the MCP configuration-file row when no file exists.
- Preserved the hidden GR III Sky Orange preset for restoring older photos and custom films, with synchronized Swift, Go and Windows color data.

### Download and upgrade

- **Mac**: Apple Silicon, macOS 14 or later. The DMG and included app are Developer ID signed, Apple notarized and stapled, and have passed Gatekeeper verification.
- **Windows x64 Beta**: Windows 10/11 x64, WebView2 and the VC++ x64 Runtime are required. The installer is not Authenticode signed.
- The old Swift Mac app and previous Go installations retaining its identity can upgrade through Check for Updates using the FilmYourPhoto bridge. After migration, updates use FilmDevelop and the data location stays unchanged. Both downloads remain during the transition; the updater chooses automatically.
- Migration retains old files and migration receipts without overwriting existing changes in the new version. Database transfers do not include original photos; records with only an old hash and no source path require relocation.

### Validation and known differences

- Build 1323 combines the previous release with full migration checks: bridge launch, replacement by the installer helper, standard-app restart, 16 preserved data files, acceptance by the build 1243 Go updater, and selection of a future release containing only the standard package all passed. Another 16 native and 45 desktop smoke checks passed. The standard DMG is about 83.1 MiB; the bridge DMG is about 87.9 MiB. Windows received the version and packaging update; real-machine tests were not repeated this round.

- Build 1243 was retested: all 77 Mac image comparisons before/after resource reduction are pixel-identical; 16 native checks, 45 Wails checks, real MLX inference and final DMG startup/export passed. An isolated old Swift app copy completed package selection, signature preparation, replacement and Go receipt confirmation. The latest Windows payload passed 158 file checks, GUI startup and loading of 6 native libraries. Privacy scans passed for 108 files in each Mac package and 159 Windows files.
- The build 1243 standard Mac DMG was about **83.1 MiB**, **62.5% smaller** than the withdrawn build 1208 (221.5 MiB). The September 30 Swift DMG was 96.8 MiB.
- Go race/vet, shared contracts and data checks, native Mac and real Wails smoke checks, and Windows cross-compilation and packaging checks passed. Earlier Windows 10/GTX 1060 tests covered presets, editing, export, migration, GGUF and ONNX repair; 1,216 comparisons against Swift reference images passed across CPU/GPU paths on both platforms.
- The build 1208 release checks added 289 local C++ comparisons each for CPU and GPU. On Windows 10, 158 payload files, production GUI startup, 10 WebView2 actions, 3 preference restart checks and 16 comparisons each for CPU and GPU passed. Full NSIS extraction verified 159 files, including the manifest. This final round did not repeat installation/uninstallation in the production install location.
- Shared LibRaw decoded 38 of 44 RAW samples; 37 of those passed strict cross-platform numerical comparison. Nikon HE/HE* and GoPro GPR remain gaps. Native RAW rendering, subject/depth processing, denoising, depth of field and date glyphs still differ by platform.
- The existing Swift XCTest baseline remains 10 cases with 20 failed assertions. Windows 11, clean machines without the required runtimes and other GPU drivers need broader validation.

[Feature restoration log (Traditional Chinese)](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md) · [Release validation summary](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/release-validation.json)

## 日本語

デスクトップのメイン処理と共通機能を Go／Wails に移行し、macOS の画像処理とハードウェア計算は Swift／C++ が担当します。Windows x64 Beta を追加しました。以下は v1.26.0930-build-1745 からの主な変更点です。

### 主な変更点

- Go／Swift／C++ 成果物の個人用ビルドパスを相対ソースパスに変更しました。パッケージ作成前に個人用パス、秘密鍵、一般的なトークン形式を検査します。ローカル専用の pack.command は Git と配布物に含めません。
- 旧 Swift 版の更新を修正し、一度限りのインストール識別子移行を追加しました。FilmYourPhoto 移行パッケージは署名・公証済みの標準 App を内包し、初回起動時に同じ場所で置き換えます。追加ダウンロードは不要で、以後は FilmDevelop で更新します。ハッシュ、アーキテクチャ、署名、同一 Developer Team の検証を維持します。
- パッケージを縮小しました。Mac では Windows 専用の色・編集用参照テーブルを除き、Core ML はコンパイル済みモデルのみを同梱します。両プラットフォームの Go 正式ビルドからデバッグシンボルを除去し、RAW 校色データと全機能は保持します。
- フィルムプリセット、写真管理、調整、切り抜き、修復、AI モデル、MCP、更新、書き出しの処理を両プラットフォームで共通化しました。
- Windows は利用可能な RAW デコーダーと Vulkan GPU を検出し、使える GPU を優先して、失敗時は CPU に切り替えます。設定は保存され、起動時に利用可否を再確認します。
- プレビューは写真一覧と同じサムネイルを先に表示し、調整結果を段階的に表示します。デコード済み画像、マスク、処理結果のキャッシュを再利用し、写真・フィルムの切り替えや連続調整を改善しました。通常の進捗表示は画像の下、計算バックエンドの切り替えはアニメーション付きダイアログに表示します。
- 編集済み写真の調整値が復元されない問題を修正しました。旧 Swift 版の星評価、カテゴリ、カスタムフィルム、プロンプト、マスク、モデルの対応付け、表示設定を引き継ぎます。移行記録、データベースの書き出し・読み込み、パスの再指定を追加し、新版の既存データを優先します。
- 切り抜きメニューの末尾に区切り線付きの復元項目を追加し、元のサイズと回転角度に戻せます。処理中も現在の画像を表示し続けます。
- 書き出し時の初期ファイル名を Swift 版に合わせました。EXIF の書き込みは初期状態で有効です。JPEG、PNG、WebP、TIFF で元の撮影情報を保持でき、PNG／TIFF は 8／16 bit に対応します。
- 右クリックメニューを一般的な形式に変更しました。ダイアログのボタンを横一列にそろえ、確定・キャンセル・削除を色分けしました。設定ボタンとフィルム一覧の表示も統一し、コンパクトにしました。
- 保存したカスタムフィルムは初期状態で選択されます。特大サムネイルの設定を修正し、名前を繰り返すツールチップと、設定ファイルが存在しない場合の MCP 設定ファイル欄を削除しました。
- 非表示の GR III Sky Orange プリセットを旧写真・カスタムフィルムの復元用に保持し、Swift、Go、Windows の色データを同期しました。

### ダウンロードと更新

- **Mac**：Apple Silicon、macOS 14 以降。DMG と内包アプリは Developer ID 署名、Apple 公証、公証チケット添付、Gatekeeper 検証を完了しています。
- **Windows x64 Beta**：Windows 10／11 x64、WebView2、VC++ x64 Runtime が必要です。インストーラーは Authenticode 未署名です。
- 旧 Swift Mac 版と旧識別子を保持した Go 版は、「アップデートを確認」から FilmYourPhoto 移行パッケージで更新できます。移行後は FilmDevelop を使い、データの保存先は変わりません。移行期間は両方を提供し、更新機能が自動で選択します。
- 移行では旧ファイルと移行記録を保持し、新版での既存の変更を上書きしません。別の PC へのデータベース転送に元写真は含まれません。旧ハッシュのみで元のパスがない記録は、パスの再指定が必要です。

### 検証結果と既知の差異

- build 1323 は前版の内容を統合し、移行起動、インストール helper による置換、標準 App の再起動、既存データ 16 ファイルの保持、build 1243 Go 更新機能での受け入れ、標準パッケージのみの次版の選択を検証しました。ネイティブ 16 項目・デスクトップ 45 項目も通過しました。標準 DMG は約 83.1 MiB、移行 DMG は約 87.9 MiB です。Windows はバージョン・パッケージを更新し、今回実機検証は繰り返していません。

- build 1243 を再検証しました。資源削減前後の Mac 画像 77 組は全画素が一致し、ネイティブ 16 項目、Wails 45 項目、実際の MLX 推論、最終 DMG の起動・書き出しが通過しました。隔離した旧 Swift アプリのコピーでパッケージ選択、署名検証・準備、置換、Go の更新受領確認を検証しました。最新 Windows 成果物は 158 ファイルの照合、GUI 起動、ネイティブライブラリ 6 個の読み込みが通過しました。Mac 各 108 ファイル、Windows 159 ファイルのプライバシー検査も通過しています。
- build 1243 の標準 Mac DMG は約 **83.1 MiB** で、取り下げた build 1208（221.5 MiB）より **62.5% 削減**しました。9 月 30 日の Swift DMG は 96.8 MiB でした。
- Go race／vet、共通契約・データ検査、Mac ネイティブ・実際の Wails のスモークテスト、Windows のクロスコンパイル・パッケージ検査を通過しました。前段の Windows 10／GTX 1060 実機検証ではプリセット、編集、書き出し、移行、GGUF、ONNX 修復を確認し、両プラットフォームの CPU／GPU で計 1,216 組の Swift 参照画像比較を通過しました。
- build 1208 の公開前検証ではローカル C++ の CPU／GPU 各 289 組を追加検証しました。Windows 10 では payload 158 ファイルの照合、正式 GUI 起動、WebView2 操作 10 項目、設定の再起動確認 3 項目、CPU／GPU 各 16 組の比較を通過しました。NSIS の全展開ではマニフェストを含む 159 ファイルを照合しました。この最終確認では通常のインストール先でのインストール・アンインストールは再実行していません。
- RAW サンプル 44 件中、共通 LibRaw で 38 件をデコードでき、そのうち 37 件が厳密なクロスプラットフォーム数値比較を通過しました。Nikon HE／HE* と GoPro GPR は未対応部分が残ります。ネイティブ RAW、被写体・深度処理、ノイズ除去、被写界深度、日付の字体にはプラットフォーム差があります。
- 既存の Swift XCTest は 10 ケース・20 アサーション失敗の基準状態から変化していません。Windows 11、必要なランタイムがないクリーン環境、他の GPU ドライバーは追加検証が必要です。

[機能復元記録（繁体字中国語）](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md) · [リリース検証概要](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/release-validation.json)

## 한국어

데스크톱 주 프로그램과 공통 기능을 Go/Wails로 이전했으며, macOS의 이미지 처리와 하드웨어 연산은 Swift/C++가 담당합니다. Windows x64 Beta를 추가했습니다. 다음은 v1.26.0930-build-1745 대비 주요 변경 사항입니다.

### 주요 변경 사항

- Go/Swift/C++ 결과물의 개인 빌드 경로를 상대 소스 경로로 변경했습니다. 패키징 전에 개인 경로, 개인 키 및 일반적인 토큰 형식을 검사합니다. 로컬 pack.command는 Git과 배포 파일에 포함하지 않습니다.
- 이전 Swift 앱의 업데이트 문제를 수정하고 일회성 설치 식별자 이전을 추가했습니다. FilmYourPhoto 전환 패키지는 서명·공증된 표준 앱을 포함하며 첫 실행 시 같은 위치에서 교체됩니다. 추가 다운로드 없이 이후에는 FilmDevelop으로 업데이트합니다. 해시, 아키텍처, 서명 및 동일 Developer Team 검증을 유지합니다.
- 패키지 크기를 줄였습니다. Mac에서는 Windows 전용 색상·편집 참조표를 제외하고 컴파일된 Core ML 모델만 포함합니다. 두 플랫폼의 정식 Go 빌드에서 디버그 심볼을 제거하며, RAW 색상 보정 데이터와 모든 기능은 유지합니다.
- 필름 프리셋, 사진 관리, 조정, 자르기, 복구, AI 모델, MCP, 업데이트 및 내보내기 흐름을 두 플랫폼에서 공유합니다.
- Windows에서 사용 가능한 RAW 디코더와 Vulkan GPU를 감지하고, 사용 가능한 GPU를 우선하며 실패 시 CPU로 전환합니다. 설정을 저장하고 시작할 때 사용 가능 여부를 다시 확인합니다.
- 미리보기는 사진 목록과 같은 썸네일을 먼저 표시한 뒤 조정 결과를 점진적으로 보여 줍니다. 디코딩 이미지, 마스크 및 처리 결과 캐시를 재사용하여 사진·필름 전환과 연속 조정을 개선했습니다. 일반 진행 상태는 이미지 아래에 표시하고, 연산 백엔드 전환 시에는 애니메이션 대화상자를 표시합니다.
- 편집한 사진의 조정값이 복원되지 않는 문제를 수정했습니다. 이전 Swift 버전의 별점, 분류, 사용자 필름, 프롬프트, 마스크, 모델 연결 및 인터페이스 설정을 이전합니다. 이전 기록, 데이터베이스 내보내기·가져오기 및 경로 재지정을 추가했으며, 새 버전의 기존 데이터를 우선합니다.
- 자르기 메뉴 마지막에 구분선과 복원 항목을 추가하여 원래 크기와 회전 각도로 되돌릴 수 있습니다. 처리 중에도 현재 이미지를 유지합니다.
- 기본 내보내기 파일명을 Swift 버전과 일치시켰습니다. EXIF 기록은 기본으로 켜져 있습니다. JPEG, PNG, WebP, TIFF에서 원본 촬영 정보를 유지할 수 있으며 PNG/TIFF는 8/16 bit를 지원합니다.
- 우클릭 메뉴를 일반적인 메뉴 형식으로 변경했습니다. 대화상자 버튼을 한 줄로 배치하고 확인·취소·삭제를 색상으로 구분했습니다. 설정 버튼과 필름 목록의 모양을 통일하고 더 간결하게 정리했습니다.
- 새로 저장한 사용자 필름은 기본으로 선택됩니다. 매우 큰 썸네일 설정을 수정하고, 이름만 반복하는 툴팁과 설정 파일이 없을 때의 MCP 설정 파일 행을 제거했습니다.
- 이전 사진과 사용자 필름 복원을 위해 숨겨진 GR III Sky Orange 프리셋을 유지하고 Swift, Go 및 Windows 색상 데이터를 동기화했습니다.

### 다운로드 및 업그레이드

- **Mac**: Apple Silicon, macOS 14 이상. DMG와 포함된 앱은 Developer ID 서명, Apple 공증, 공증 티켓 첨부 및 Gatekeeper 검증을 완료했습니다.
- **Windows x64 Beta**: Windows 10/11 x64, WebView2 및 VC++ x64 Runtime이 필요합니다. 설치 파일은 Authenticode 서명이 없습니다.
- 이전 Swift Mac 앱과 이전 식별자를 유지한 Go 앱은 업데이트 확인에서 FilmYourPhoto 전환 패키지로 업그레이드할 수 있습니다. 이전 후에는 FilmDevelop을 사용하며 데이터 위치는 유지됩니다. 전환 기간에는 두 다운로드를 제공하고 업데이트 기능이 자동으로 선택합니다.
- 데이터 이전은 기존 파일과 이전 기록을 보존하며 새 버전의 기존 변경 내용을 덮어쓰지 않습니다. 다른 컴퓨터로 옮기는 데이터베이스 패키지에는 원본 사진이 포함되지 않습니다. 이전 해시만 있고 원본 경로가 없는 기록은 경로를 다시 지정해야 합니다.

### 검증 및 알려진 차이

- build 1323은 이전 릴리스 내용을 통합하고 전환 앱 실행, 설치 helper의 교체, 표준 앱 재실행, 기존 데이터 파일 16개 보존, build 1243 Go 업데이트 기능의 호환 패키지 수락 및 표준 패키지만 제공하는 다음 버전 선택을 검증했습니다. 네이티브 16개와 데스크톱 45개 검사도 통과했습니다. 표준 DMG는 약 83.1 MiB, 전환 DMG는 약 87.9 MiB입니다. Windows 버전과 패키지를 업데이트했으며 이번에는 실기기 검증을 반복하지 않았습니다.

- build 1243을 다시 검증했습니다. 리소스 축소 전후 Mac 이미지 77개 비교가 모든 픽셀에서 일치했으며, 네이티브 16개, Wails 45개 검사, 실제 MLX 추론 및 최종 DMG 실행·내보내기를 통과했습니다. 격리된 이전 Swift 앱 복사본에서 패키지 선택, 서명 검증·준비, 교체 및 Go 업데이트 수신 확인을 검증했습니다. 최신 Windows 결과물은 파일 158개 검증, GUI 실행 및 네이티브 라이브러리 6개 로드를 통과했습니다. Mac 패키지당 108개 파일과 Windows 159개 파일의 개인정보 검사도 통과했습니다.
- build 1243 표준 Mac DMG는 약 **83.1 MiB**로, 철회한 build 1208(221.5 MiB)보다 **62.5% 감소**했습니다. 9월 30일 Swift DMG는 96.8 MiB였습니다.
- Go race/vet, 공통 계약 및 데이터 검사, Mac 네이티브와 실제 Wails 스모크 테스트, Windows 교차 컴파일 및 패키지 검사를 통과했습니다. 앞선 Windows 10/GTX 1060 실기기 검증은 프리셋, 편집, 내보내기, 데이터 이전, GGUF 및 ONNX 복구를 포함하며, 두 플랫폼의 CPU/GPU 경로에서 Swift 참조 이미지 비교 총 1,216건을 통과했습니다.
- build 1208 공개 전 검증에서는 로컬 C++ CPU/GPU 각각 289건을 추가로 검증했습니다. Windows 10에서 payload 파일 158개 검증, 정식 GUI 시작, WebView2 동작 10개, 설정 재시작 검사 3개 및 CPU/GPU 각각 16건의 비교를 통과했습니다. NSIS 전체 압축 해제 후 목록 파일을 포함한 159개 파일을 검증했습니다. 이번 최종 확인에서는 실제 사용 중인 설치 위치에서 설치·제거를 다시 실행하지 않았습니다.
- RAW 샘플 44개 중 공통 LibRaw가 38개를 디코딩했으며, 그중 37개가 엄격한 플랫폼 간 수치 비교를 통과했습니다. Nikon HE/HE*와 GoPro GPR에는 아직 지원 공백이 있습니다. 네이티브 RAW, 피사체·깊이 처리, 노이즈 제거, 피사계 심도 및 날짜 글꼴에는 플랫폼별 차이가 남아 있습니다.
- 기존 Swift XCTest의 기준 상태인 10개 사례와 20개 실패 단언은 변하지 않았습니다. Windows 11, 필수 런타임이 없는 새 환경 및 다른 GPU 드라이버는 추가 검증이 필요합니다.

[기능 복원 기록(번체 중국어)](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md) · [릴리스 검증 요약](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1002-build-1323/release-validation.json)
