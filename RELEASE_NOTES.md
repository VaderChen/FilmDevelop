[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/FilmDevelop-1.26.1003-build1503-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/FilmDevelop-1.26.1003-build1503-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/FilmYourPhoto-1.26.1003-build-1503-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/SHA256SUMS.txt)

## 繁體中文

相較版本：**1.26.1003 build 1300**。

- **改善**：最佳化配方編輯、驗證與自訂底片預設，減少重複 JSON 解碼、複製及記憶體配置，保留既有功能、畫面與操作流程。
- **改善**：遮罩資產改用最多 64 KiB 的串流緩衝區完成驗證與重複匯入比對；保留完整內容、尺寸及 SHA-256 檢查。
- **改善**：模型配對每個候選只評分一次，照片自然排序每個檔案只建立一次排序鍵；維持原配對判斷、同分處理、順序及縮圖識別。
- **改善**：最佳化 CPU Gaussian 取樣，維持原有浮點精度、權重及累加順序；macOS 與 Windows 各通過 114 組逐位元對照，Windows CPU／Vulkan 各 10 份匯出與 build 1300 完全相同。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)

## English

Compared with: **1.26.1003 build 1300**。

- **Improved**：Optimize recipe editing, validation and custom-film defaults by reducing repeated JSON decoding, copying and allocations, preserving features, layout and workflow.
- **Improved**：Validate mask assets and compare existing imports with a streaming buffer capped at 64 KiB, retaining full content, dimensions and SHA-256 checks.
- **Improved**：Score each model-pairing candidate once and build natural-sort keys once per photo, retaining pairing decisions, tie handling, ordering and thumbnail identities.
- **Improved**：Optimize CPU Gaussian sampling while preserving floating-point precision, weights and accumulation order. All 114 bit-exact cases pass on both macOS and Windows; 10 exports per Windows CPU/Vulkan backend match build 1300 byte for byte.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)

## 日本語

比較元：**1.26.1003 build 1300**。

- **改善**：配方編集・検証とカスタムフィルムの初期値を最適化し、JSON の重複デコード、コピー、メモリ割り当てを削減。既存機能、画面、操作手順を維持します。
- **改善**：マスク資産の検証と既存データとの照合を最大 64 KiB のストリームバッファで実行。全内容、寸法、SHA-256 の検証を維持します。
- **改善**：モデル対応候補の評価と写真の自然順ソートキーの生成を各 1 回に削減。対応判定、同点処理、並び順、サムネイル識別を維持します。
- **改善**：CPU Gaussian のサンプリングを最適化し、浮動小数点精度、重み、加算順序を維持。macOS・Windows で各 114 件のビット単位比較に合格し、Windows CPU／Vulkan 各 10 件の書き出しが build 1300 と完全一致。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)

## 한국어

비교 버전: **1.26.1003 build 1300**。

- **개선**：레시피 편집·검증과 사용자 필름 기본값을 최적화하여 반복 JSON 디코딩, 복사 및 메모리 할당을 줄입니다. 기존 기능, 화면과 작업 흐름은 유지합니다.
- **개선**：최대 64 KiB의 스트리밍 버퍼로 마스크 자산을 검증하고 기존 가져오기와 비교합니다. 전체 내용, 크기 및 SHA-256 검사는 유지합니다.
- **개선**：모델 연결 후보 평가는 후보당 한 번, 사진의 자연 정렬 키 생성은 파일당 한 번만 수행합니다. 연결 판단, 동점 처리, 순서와 썸네일 식별은 유지합니다.
- **개선**：CPU Gaussian 샘플링을 최적화하며 부동소수점 정밀도, 가중치와 누적 순서를 유지합니다. macOS와 Windows 각각 114건의 비트 단위 비교를 통과했으며 Windows CPU/Vulkan별 내보내기 10건이 build 1300과 완전히 일치합니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1503/release-validation.json)
