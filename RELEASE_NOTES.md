[繁體中文](#繁體中文) · [English](#english) · [日本語](#日本語) · [한국어](#한국어)

[macOS Apple Silicon DMG](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/FilmDevelop-1.26.1004-build0036-macos-arm64.dmg) · [Windows x64 Beta](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/FilmDevelop-1.26.1004-build0036-windows-x64-portable.zip) · [Swift Mac upgrade](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/FilmYourPhoto-1.26.1004-build-0036-arm64.dmg) · [SHA-256](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/SHA256SUMS.txt)

## 繁體中文

相較版本：**1.26.1003 build 1503**。

- **改善**：柔膚改用多尺度亮度處理，優先改善局部明暗不均並保留細紋、原膚色與立體光影；增加滑桿中高段的作用，末段混合強度不再提前封頂。
- **改善**：美白改為保留個人底色的明度曲線，不再統一降低飽和度與反差；加強滑桿提亮效果，同時保護高光、純黑、HDR 與透明度。
- **修正**：改善欠曝膚色辨識，人物遮罩外與完全透明區域不再殘留膚質效果；增加偏紅細節保護，遮罩細化後再次排除低可信區域。
- **修正**：統一跨平台降噪的逐通道保邊處理，修正中段作用偏弱及透明像素污染鄰近色彩；效果混合沿用來源覆蓋率，避免半透明影像越調越不透明。
- **修正**：分區淡化改用共同的單調亮度曲線，修正強烈暗部淡化時相鄰階調反轉；保留既有分區控制與操作方式。
- **修正**：HDR 對數亮度重建保留純黑與極暗階調，避免數值穩定處理抬升黑位或截斷暗部；保留自訂黑位控制與浮點高光。
- **改善**：統一導向濾波的取樣座標及上採樣，減少預覽、匯出與分塊運算差異；小型係數圖保留在 GPU 並沿用容量上限，減少 CPU 讀回與再次上傳。

[原始碼差異](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1503...v1.26.1004-build-0036) · [驗證紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/desktop/RESTORATION.md)

[完整更新紀錄](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/CHANGELOG.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/README.md) · [驗證紀錄 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/release-validation.json)

## English

Compared with: **1.26.1003 build 1503**。

- **Improved**：Skin smoothing now uses multiple luminance scales to reduce local unevenness while retaining fine texture, undertones and facial shading. Mid-to-high slider settings are stronger, and the blend strength no longer reaches its cap early.
- **Improved**：Skin brightening now uses a lightness curve that preserves individual undertones instead of uniformly reducing saturation and contrast. Stronger slider response retains protection for highlights, black, HDR and alpha.
- **Fixed**：Improve underexposed skin detection and remove residual skin effects outside the person mask and in fully transparent areas. Protect strongly red details and reapply confidence exclusions after mask refinement.
- **Fixed**：Align edge-preserving channel-wise denoising across platforms, fixing weak midrange response and color contamination from transparent pixels. Effect blending preserves source coverage so semi-transparent images do not become more opaque.
- **Fixed**：Use a shared monotonic luminance curve for tonal-zone fade, preventing adjacent tones from reversing under strong shadow fade while retaining existing zone controls and workflow.
- **Fixed**：HDR log-luminance reconstruction preserves black and near-black gradations, avoiding lifted blacks or clipped shadows from numerical stabilization. Custom black-level controls and floating-point highlights remain available.
- **Improved**：Align guided-filter sampling coordinates and upsampling to reduce differences between previews, exports and tiled rendering. Keep small coefficient images on the GPU within existing cache limits to avoid CPU readback and re-upload.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1503...v1.26.1004-build-0036) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/desktop/RESTORATION.md)

[Full changelog](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/CHANGELOG.en.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/README.en.md) · [Validation record (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/release-validation.json)

## 日本語

比較元：**1.26.1003 build 1503**。

- **改善**：肌のスムージングを複数スケールの輝度処理に変更し、細かな質感、元の肌色、立体的な陰影を保ちながら明暗のむらを抑えます。スライダー中～高域の効果を強め、混合強度が途中で上限に達する制限を除きました。
- **改善**：美白を個人の肌色を保つ明度カーブに変更し、一律の彩度・コントラスト低下を廃止しました。スライダーの明るさ補正を強めつつ、ハイライト、黒、HDR、透明度を保護します。
- **修正**：露出不足の肌色認識を改善し、人物マスクの外側や完全に透明な領域に肌補正が残る問題を修正。赤みの強い細部を保護し、マスク精細化後も信頼度の低い領域を除外します。
- **修正**：プラットフォーム間のエッジ保持型チャンネル別ノイズ除去を統一し、中間強度の弱さと透明画素による周囲の色への影響を修正。効果の混合で元の透明度を保ち、半透明画像が不透明になる問題を防ぎます。
- **修正**：階調別フェードに共通の単調輝度カーブを使用し、シャドウを強くフェードした際の隣接階調の反転を修正。既存の領域別コントロールと操作手順を維持します。
- **修正**：HDR の対数輝度再構成で黒と極暗部の階調を保持し、数値安定化による黒浮きや暗部の切り捨てを修正。任意の黒レベル調整と浮動小数点ハイライトは維持します。
- **改善**：ガイドフィルターのサンプリング座標とアップサンプリングを統一し、プレビュー、書き出し、タイル処理の差を低減。小さな係数画像を既存のキャッシュ上限内で GPU に保持し、CPU 読み戻しと再転送を削減します。

[ソースの差分](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1503...v1.26.1004-build-0036) · [検証記録](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/desktop/RESTORATION.md)

[変更履歴](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/CHANGELOG.ja.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/README.ja.md) · [検証記録 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/release-validation.json)

## 한국어

비교 버전: **1.26.1003 build 1503**。

- **개선**：피부 스무딩을 다중 스케일 휘도 처리로 바꾸어 미세한 질감, 원래 피부색과 입체적인 음영을 유지하면서 국소적인 밝기 불균일을 줄입니다. 슬라이더 중·고강도 효과를 높이고 혼합 강도가 중간에 상한에 도달하던 제한을 없앴습니다.
- **개선**：피부 미백을 개인의 원래 색조를 유지하는 명도 곡선으로 변경하여 일괄적인 채도·대비 감소를 없앴습니다. 슬라이더의 밝기 효과를 높이면서 하이라이트, 검정, HDR과 투명도를 보호합니다.
- **수정**：노출이 부족한 피부색 인식을 개선하고 인물 마스크 밖과 완전히 투명한 영역에 남던 피부 보정을 제거했습니다. 붉은 세부 영역을 보호하고 마스크 정제 후에도 신뢰도가 낮은 영역을 제외합니다.
- **수정**：플랫폼 간 채널별 에지 보존 노이즈 제거를 통일하여 중간 강도의 약한 반응과 투명 픽셀로 인한 주변 색 오염을 수정했습니다. 효과 혼합 시 원래 알파를 유지하여 반투명 이미지가 더 불투명해지는 문제를 방지합니다.
- **수정**：명암 영역별 페이드에 공통 단조 휘도 곡선을 적용하여 강한 그림자 페이드에서 인접 계조가 뒤집히는 문제를 수정했습니다. 기존 영역별 제어와 작업 흐름은 유지합니다.
- **수정**：HDR 로그 휘도 복원에서 검정과 극암부 계조를 보존하여 수치 안정화로 검정이 들뜨거나 어두운 계조가 잘리는 문제를 수정했습니다. 사용자 검정 레벨과 부동소수점 하이라이트는 유지합니다.
- **개선**：가이드 필터의 샘플링 좌표와 업샘플링을 통일하여 미리보기, 내보내기와 타일 처리 간 차이를 줄입니다. 작은 계수 이미지를 기존 캐시 한도 내에서 GPU에 유지하여 CPU 읽기와 재전송을 줄입니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1503...v1.26.1004-build-0036) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/desktop/RESTORATION.md)

[전체 변경 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/CHANGELOG.ko.md) · [README](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/README.ko.md) · [검증 기록 (JSON)](https://github.com/VaderChen/FilmDevelop/releases/download/v1.26.1004-build-0036/release-validation.json)
