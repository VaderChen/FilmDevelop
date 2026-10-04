[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/FilmDevelop-1.26.1004-build1004-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/FilmDevelop-1.26.1004-build1004-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/FilmYourPhoto-1.26.1004-build-1004-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/SHA256SUMS.txt)

## 繁體中文

相較版本：**1.26.1004 build 0036**。

- **新增**：在修復筆刷左邊加入液化筆刷，提供局部推移、局部還原、半徑與強度控制；逐筆保存並支援復原／重做，重開照片及原尺寸匯出保留變形，不需下載模型。
- **新增**：液化與修復筆刷支援 Shift＋滾輪調整大小，向上放大、向下縮小，滑桿與游標同步；維持既有範圍，調整大小不新增修圖歷史。
- **改善**：統一照片工具列下拉選單的高度、間距、箭頭與焦點樣式，改善四語文字顯示；修正液化及修復工具列在深色主題的背景。
- **改善**：逐函式最佳化液化網格驗證、序列化、歷史與原生取樣，重用未變形來源像素與不可變網格；減少重複解碼、配置及局部筆畫暫存，維持既有筆刷效果與浮點色彩精度。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1004-build-0036...v1.26.1004-build-1004) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/desktop/RESTORATION.md)

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/release-validation.json)

## English

Compared with: **1.26.1004 build 0036**。

- **Added**：Add a liquify brush to the left of the repair brush, with local push and restore modes, radius and strength controls. Strokes support undo/redo, persist when reopening photos and apply to full-resolution exports without downloading a model.
- **Added**：Hold Shift and scroll to resize liquify and repair brushes: up increases and down decreases the size, with synchronized sliders and cursors. Existing limits are preserved, and resizing does not add an edit to history.
- **Improved**：Unify photo-toolbar dropdown heights, spacing, arrows and focus styling for all four languages. Correct the dark-theme backgrounds of the liquify and repair toolbars.
- **Improved**：Optimize liquify validation, serialization, history and native sampling at function level. Reuse undeformed source pixels and immutable meshes to reduce repeated decoding, allocations and local-stroke scratch storage while preserving brush behavior and floating-point color precision.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1004-build-0036...v1.26.1004-build-1004) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/desktop/RESTORATION.md)

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/release-validation.json)

## 日本語

比較元：**1.26.1004 build 0036**。

- **追加**：修復ブラシの左にゆがみブラシを追加。局所的な移動・復元、半径・強度の調整に対応します。ストローク単位の保存と取り消し／やり直しが可能で、写真の再表示や元の解像度での書き出しにも変形が反映されます。モデルのダウンロードは不要です。
- **追加**：ゆがみ・修復ブラシで Shift＋ホイールによるサイズ変更に対応。上で拡大、下で縮小し、スライダーとカーソルが連動します。既存の範囲を維持し、サイズ変更は編集履歴に追加されません。
- **改善**：写真ツールバーのプルダウンの高さ、余白、矢印、フォーカス表示を統一し、4 言語の文字表示を改善。ダークテーマでのゆがみ・修復ツールバーの背景を修正しました。
- **改善**：ゆがみの検証、シリアライズ、履歴、ネイティブサンプリングを関数単位で最適化。変形前の画素と不変のメッシュを再利用し、ブラシの効果と浮動小数点の色精度を保ちながら、重複デコード、メモリ確保、局所ストロークの一時領域を削減します。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1004-build-0036...v1.26.1004-build-1004) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/desktop/RESTORATION.md)

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/release-validation.json)

## 한국어

비교 버전: **1.26.1004 build 0036**。

- **추가**：복구 브러시 왼쪽에 유동화 브러시를 추가했습니다. 부분 밀기·복원과 반경·강도 조절을 지원합니다. 획별 저장 및 실행 취소·다시 실행이 가능하며, 사진을 다시 열거나 원본 해상도로 내보낼 때도 변형이 유지됩니다. 모델 다운로드가 필요하지 않습니다.
- **추가**：유동화·복구 브러시에서 Shift＋휠로 크기를 조절할 수 있습니다. 위로 스크롤하면 커지고 아래로 스크롤하면 작아지며 슬라이더와 커서가 동기화됩니다. 기존 범위를 유지하고 크기 조절은 편집 기록에 추가되지 않습니다.
- **개선**：사진 도구 모음 드롭다운의 높이, 간격, 화살표와 포커스 스타일을 통일하여 네 언어의 텍스트 표시를 개선했습니다. 어두운 테마에서 유동화·복구 도구 모음 배경도 수정했습니다.
- **개선**：유동화 검증, 직렬화, 기록과 네이티브 샘플링을 함수 단위로 최적화했습니다. 변형 전 원본 픽셀과 불변 메시를 재사용하여 브러시 효과 및 부동소수점 색 정밀도를 유지하면서 중복 디코딩, 메모리 할당과 국소 획의 임시 저장 공간을 줄입니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1004-build-0036...v1.26.1004-build-1004) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/desktop/RESTORATION.md)

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-1004/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-1004/release-validation.json)
