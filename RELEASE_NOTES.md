[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/FilmDevelop-1.26.1003-build1109-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/FilmDevelop-1.26.1003-build1109-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/FilmYourPhoto-1.26.1003-build-1109-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/SHA256SUMS.txt)

## 繁體中文

此發布說明已合併 **1.26.1003 build 1026**, **1.26.1003 build 0924** 的更新，以下按版本列出差異。

### 本版更新

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

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/release-validation.json)

## English

These release notes include the changes from **1.26.1003 build 1026**, **1.26.1003 build 0924**, grouped by version below.

### Changes in this release

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

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/release-validation.json)

## 日本語

このリリースノートには **1.26.1003 build 1026**, **1.26.1003 build 0924** の更新内容を統合し、以下にバージョン別の差分を記載しています。

### 今回の更新

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

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/release-validation.json)

## 한국어

이 릴리스 노트는 **1.26.1003 build 1026**, **1.26.1003 build 0924**의 변경 사항을 통합하며, 아래에 버전별 차이를 표시합니다.

### 이번 릴리스의 변경 사항

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

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1003-build-1109/release-validation.json)
