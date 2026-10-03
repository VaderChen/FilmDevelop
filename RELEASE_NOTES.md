[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/FilmDevelop-1.26.1003-build1300-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/FilmDevelop-1.26.1003-build1300-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/FilmYourPhoto-1.26.1003-build-1300-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/SHA256SUMS.txt)

## 繁體中文

相較版本：**1.26.1003 build 1109**。

- **修正**：修正外接磁碟 JPEG 匯出失敗，恢復單張與 MCP 顯影對話框、複選匯出張數與階段進度，確認取代後繼續保護來源照片。
- **修正**：第二輪修正 12 項 Swift 移植缺漏：底片重選、重設歷史、預覽重試、修復取消、直式裁切標籤、提示詞語言、PNG 8-bit 預設、自訂底片的儲存／複製／刪除／匯出，以及 RAW 切換失敗還原。
- **修正**：保留上一輪 13 項修正，包含 AI 七階段與取消、遮罩有效性、MCP 匯出設定、完整複選重設、照片副本定位與原生拖放。
- **修正 · Windows**：Windows 下載格式與本機模型選單隱藏 MLX，預設使用 GGUF；後端拒絕不支援平台的 MLX 下載，已下載檔案保留並顯示相容性說明。 同一目錄中的具名 mmproj 可正確配對；不猜測同分或不明確的組合。
- **改善**：減少狀態快照與復原歷史的重複配置，共用不可變影像字串與修復資料，清空淘汰紀錄參照；保持既有照片處理及介面版型。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/release-validation.json)

## English

Compared with: **1.26.1003 build 1109**。

- **Fixed**：Fix external-volume JPEG export failures and restore single-image and MCP development dialogs, batch counts and stage progress while protecting source photos.
- **Fixed**：Fix 12 additional Swift migration gaps in preset reselection, reset history, preview retry, repair cancellation, portrait crop labels, prompt language, the 8-bit PNG default, custom-film save/copy/delete/export, and RAW-switch rollback.
- **Fixed**：Retain the previous 13 fixes, including seven-stage AI progress and cancellation, mask validity, MCP export settings, multi-photo reset, duplicate selection and native drag-and-drop.
- **Fixed · Windows**：Hide MLX from Windows download and local-model selectors and default to GGUF. Reject unsupported MLX downloads; retain existing files with a compatibility explanation. Match named mmproj files in shared directories and reject ambiguous pairs.
- **Improved**：Reduce allocations in state snapshots and edit history by sharing immutable image and repair data and releasing evicted references, preserving image processing and interface layout.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/release-validation.json)

## 日本語

比較元：**1.26.1003 build 1109**。

- **修正**：外部ドライブの JPEG 書き出し失敗を修正。単一画像と MCP の現像表示、一括処理の枚数と進捗を復元し、元画像を保護します。
- **修正**：フィルム再選択、リセット履歴、プレビュー再試行、修復キャンセル、縦写真の比率、プロンプト言語、PNG 8-bit 既定値、カスタムフィルム操作、RAW 切替失敗時の復元など、追加の移植漏れ 12 件を修正。
- **修正**：前回の修正 13 件を維持。AI の 7 段階表示とキャンセル、マスク検証、MCP 書き出し設定、複数写真のリセット、複製選択、ドラッグ読込を含みます。
- **修正 · Windows**：Windows のダウンロード形式とローカルモデル選択から MLX を非表示にし、GGUF を既定に変更。非対応 MLX のダウンロードを拒否し、既存ファイルは説明とともに保持します。 同じフォルダ内の型名付き mmproj を正しく対応付け、曖昧な組み合わせは拒否します。
- **改善**：不変の画像・修復データの共有と破棄した履歴の参照解放により、状態と履歴のメモリ割り当てを削減。画像処理と画面構成は維持します。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/release-validation.json)

## 한국어

비교 버전: **1.26.1003 build 1109**。

- **수정**：외장 드라이브의 JPEG 내보내기 실패를 수정하고 단일 이미지와 MCP 현상 창, 일괄 작업 장수와 진행률을 복원하며 원본 사진을 보호합니다.
- **수정**：필름 재선택, 초기화 기록, 미리보기 재시도, 복구 취소, 세로 사진 비율, 프롬프트 언어, PNG 8-bit 기본값, 사용자 필름 작업 및 RAW 전환 실패 복원 등 추가 이식 누락 12건을 수정했습니다.
- **수정**：AI 7단계 진행률과 취소, 마스크 검증, MCP 내보내기 설정, 다중 사진 초기화, 복사본 선택 및 드래그 열기 등 이전 수정 13건을 유지합니다.
- **수정 · Windows**：Windows 다운로드 형식과 로컬 모델 선택에서 MLX를 숨기고 GGUF를 기본값으로 사용합니다. 지원하지 않는 MLX 다운로드를 거부하고 기존 파일은 호환성 안내와 함께 유지합니다. 같은 폴더의 모델명이 포함된 mmproj를 올바르게 연결하고 모호한 조합은 거부합니다.
- **개선**：불변 이미지와 복구 데이터를 공유하고 제거된 기록의 참조를 해제하여 상태와 편집 기록의 메모리 할당을 줄입니다. 이미지 처리와 화면 구성은 유지합니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1300/release-validation.json)
