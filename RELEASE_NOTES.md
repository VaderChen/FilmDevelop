[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/FilmDevelop-1.26.1003-build0018-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/FilmDevelop-1.26.1003-build0018-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/FilmYourPhoto-1.26.1003-build-0018-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/SHA256SUMS.txt)

## 繁體中文

此發布說明已合併 **1.26.1002 build 2330** 的更新，以下按版本列出差異。

### 本版更新

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

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/release-validation.json)

## English

These release notes include the changes from **1.26.1002 build 2330**, grouped by version below.

### Changes in this release

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

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/release-validation.json)

## 日本語

このリリースノートには **1.26.1002 build 2330** の更新内容を統合し、以下にバージョン別の差分を記載しています。

### 今回の更新

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

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/release-validation.json)

## 한국어

이 릴리스 노트는 **1.26.1002 build 2330**의 변경 사항을 통합하며, 아래에 버전별 차이를 표시합니다.

### 이번 릴리스의 변경 사항

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

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0018/release-validation.json)
