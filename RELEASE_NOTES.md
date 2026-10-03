[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/FilmDevelop-1.26.1003-build0924-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/FilmDevelop-1.26.1003-build0924-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/FilmYourPhoto-1.26.1003-build-0924-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/SHA256SUMS.txt)

## 繁體中文

相較版本：**1.26.1003 build 0018**。

- **修正**：補上 Nikon HE／HE* NEF 與 GoPro GPR 的共同解碼流程：系統或 LibRaw 缺少解碼器時，使用已安裝的 Adobe DNG Converter 建立無損 RAW 快取，支援 Mac 與 Windows。
- **新增**：缺少補充解碼器時，在照片下方提供 Adobe 官方下載與重新偵測入口；使用者需自行完成原廠安裝。FilmDevelop 不內附 Adobe Converter，一般預覽不自動跳出安裝對話框。
- **修正**：GPR 加入照片匯入及兩平台 RAW 辨識；沒有可用內嵌縮圖時也能補充解碼，安裝後重新偵測可恢復列表縮圖。
- **改善**：補充解碼保留原始照片、調整識別與拍攝 EXIF；快取有內容驗證、容量上限、取消與結束清理。完整感光資料仍由共用 LibRaw 顯影，不以相機 JPEG 取代編輯來源。
- **改善**：補驗 Mac 47 張 RAW 的 141 次預覽／匯出、Windows 20 張的 60 次工作及預設系統模式 42 次工作；公開 EXIF、尺寸及像素差異紀錄。未知格式、JPEG XL／Enhanced DNG 與逐像素一致性仍有限制。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/release-validation.json)

## English

Compared with: **1.26.1003 build 0018**。

- **Fixed**：Added a shared decoding fallback for Nikon HE/HE* NEF and GoPro GPR on Mac and Windows. When the system or LibRaw lacks a decoder, an installed Adobe DNG Converter creates a lossless RAW cache.
- **Added**：When the additional decoder is missing, the photo footer offers Adobe’s official download page and a check-again action. Users complete Adobe’s installation themselves. FilmDevelop does not bundle the converter or automatically open an installation dialog during preview.
- **Fixed**：GPR is now recognized by photo import and both RAW engines. Files without a usable embedded thumbnail can use the supplemental decoder, and checking again after installation restores failed list thumbnails.
- **Improved**：Supplemental decoding preserves original photos, edit identities and capture EXIF. The cache validates content, has a size limit, supports cancellation and is removed on exit. Shared LibRaw still develops the full sensor data; camera JPEGs are not used as editing sources.
- **Improved**：Validated 141 preview/export operations across 47 RAW files on Mac, 60 operations across 20 files on Windows, and 42 Windows System-mode operations. EXIF, dimensions and pixel differences are documented; unknown formats, JPEG XL/Enhanced DNG and pixel identity remain limited.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/release-validation.json)

## 日本語

比較元：**1.26.1003 build 0018**。

- **修正**：Mac と Windows に Nikon HE／HE* NEF と GoPro GPR の共通代替デコード経路を追加。システムや LibRaw にデコーダーがない場合、インストール済みの Adobe DNG Converter でロスレス RAW キャッシュを作成します。
- **追加**：追加デコーダーがない場合は写真の下部に Adobe 公式ダウンロードと再検出の操作を表示します。Adobe のインストールは利用者が完了してください。Converter は同梱せず、通常のプレビュー中にインストール画面を自動表示しません。
- **修正**：GPR を写真読み込みと両プラットフォームの RAW 判定に追加。利用可能な埋め込みサムネイルがない場合も追加デコードを利用でき、インストール後の再検出で一覧サムネイルを再試行します。
- **改善**：追加デコードでは元写真、編集の識別情報、撮影 EXIF を保持します。キャッシュは内容検証、容量制限、キャンセル、終了時の削除に対応。共通 LibRaw が全画素のセンサーデータを現像し、カメラ内 JPEG を編集元にしません。
- **改善**：Mac の RAW 47 ファイルでプレビュー・書き出し 141 回、Windows の 20 ファイルで 60 回、システム設定で 42 回を検証。EXIF、寸法、画素差を記録しました。未知の形式、JPEG XL／Enhanced DNG、画素単位の一致には制限が残ります。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/release-validation.json)

## 한국어

비교 버전: **1.26.1003 build 0018**。

- **수정**：Mac과 Windows에 Nikon HE/HE* NEF 및 GoPro GPR의 공통 대체 디코딩 경로를 추가했습니다. 시스템이나 LibRaw에 디코더가 없으면 설치된 Adobe DNG Converter로 무손실 RAW 캐시를 만듭니다.
- **추가**：추가 디코더가 없으면 사진 아래에 Adobe 공식 다운로드와 다시 검색 기능을 표시합니다. Adobe 설치는 사용자가 직접 완료해야 합니다. Converter는 포함하지 않으며 일반 미리보기에서 설치 대화상자를 자동으로 열지 않습니다.
- **수정**：사진 가져오기와 두 플랫폼의 RAW 인식에 GPR을 추가했습니다. 사용할 수 있는 내장 썸네일이 없어도 추가 디코딩을 사용하며 설치 후 다시 검색하면 실패한 목록 썸네일을 다시 불러옵니다.
- **개선**：추가 디코딩은 원본 사진, 편집 식별 정보와 촬영 EXIF를 보존합니다. 캐시는 내용 검사, 용량 제한, 취소와 종료 시 정리를 지원합니다. 공통 LibRaw가 전체 센서 데이터를 현상하며 카메라 JPEG를 편집 원본으로 사용하지 않습니다.
- **개선**：Mac RAW 47개에서 미리보기·내보내기 141회, Windows 20개에서 60회 및 시스템 모드 42회를 검증했습니다. EXIF, 크기와 픽셀 차이를 기록했습니다. 알 수 없는 형식, JPEG XL/Enhanced DNG와 픽셀 단위 일치에는 제한이 남아 있습니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-0924/release-validation.json)
