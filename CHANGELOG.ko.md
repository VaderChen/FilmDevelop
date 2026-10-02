# 변경 기록

[繁體中文](CHANGELOG.md) · [English](CHANGELOG.en.md) · [日本語](CHANGELOG.ja.md) · [한국어](CHANGELOG.ko.md)

<!-- 由 scripts/release_notes.py 產生；請修改 history.json。 -->

## 1.26.1003 build 0018

비교 버전: **1.26.1002 build 2330**。

- **수정**：업데이트 완료 창에 실제 추가·수정·개선 사항과 비교 버전을 표시하고 선택한 UI 언어를 적용합니다.
- **수정**：여러 버전을 건너뛰면 변경 사항을 버전별로 표시합니다. 다른 대화상자가 열려 있으면 닫힌 후 업데이트 내용을 다시 표시합니다.
- **개선 · Windows**：Windows 포터블 ZIP에서 C++ 디버그 정보를 제거하고 기존 이미지 연산, 룩업 테이블, 모델과 Microsoft Runtime을 유지합니다.
- **추가**：버전별 변경 기록을 추가했습니다. README, 앱 내 요약과 GitHub Release가 4개 언어의 공통 데이터를 사용하며 build 1323 대비 build 2330의 차이도 기록합니다.
- **개선**：전체 릴리스 작업은 프로젝트의 dist를 먼저 한 번 비운 후 Mac과 Windows를 순서대로 빌드하고 버전 기록과 배포 파일 목록을 검증합니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

## 1.26.1002 build 2330

비교 버전: **1.26.1002 build 1323**。

- **수정**：목록 썸네일, 편집 썸네일과 전체 미리보기의 표시 범위를 맞춰 사진 전환 중 갑자기 확대되는 문제를 수정했습니다.
- **개선**：용량이 제한된 캐시와 C++ 작업 스레드를 재사용합니다. Mac 소프트웨어 RAW 편집 미리보기는 절반 크기로 디코딩하며 전체 해상도 미리보기와 내보내기는 전체 디코딩을 유지합니다.
- **개선**：유제 결정 계산을 공유하고 경계를 다시 계산하며 4개 샘플·3개 층·FP32를 유지합니다. 지정 조건의 유제 단계는 약 30–35% 빨라졌으며 전체 미리보기의 개선율은 아닙니다.
- **추가 · Windows**：Windows를 포터블 ZIP으로 배포하여 전체 압축 해제 후 실행할 수 있습니다. Microsoft 원본 VC++ x64 Runtime DLL 12개를 포함하며 WebView2는 여전히 필요합니다.
- **추가 · Windows**：Windows 포터블 앱에서 ZIP·개별 파일의 SHA-256을 검증하고 추가 파일을 유지하며 시작 실패 시 복구하는 업데이트를 지원합니다. 기존 setup 사용자의 첫 전환은 ZIP 수동 다운로드가 필요합니다.
- **수정**：Swift Sendable 경고와 빌드 시스템 호환성을 수정하고 Windows CPU/Vulkan 이미지 및 업데이트 검증을 보강했습니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

## 1.26.1002 build 1323

비교 버전: **1.26.0930 build 1745**。

- **추가**：공통 Go/Wails 데스크톱과 Windows x64 Beta를 추가하고 Mac은 Swift/C++ 이미지 엔진을 유지합니다.
- **수정 · macOS**：Swift Mac 앱의 직접 업데이트를 복구했습니다. FilmYourPhoto 전환 패키지가 첫 실행 시 설치 식별자를 이전하며 이후에는 표준 FilmDevelop 패키지를 사용합니다.
- **추가**：Swift 사진 편집, 별점, 분류와 사용자 필름을 가져오며 이전 기록, 데이터베이스 내보내기·가져오기·경로 재지정을 추가하고 새 버전의 기존 데이터를 보존합니다.
- **추가**：자르기 복원과 기본으로 켜진 EXIF 기록, Swift와 동일한 내보내기 이름을 추가하고 우클릭 메뉴, 동작별 버튼 색상, 간결한 목록과 사용자 필름 선택을 정리했습니다.
- **개선**：RAW와 연산 가속은 시스템을 기본값으로 설정을 저장합니다. Windows는 Vulkan GPU를 탐지하고 사용할 수 없으면 CPU로 전환합니다. 중복 리소스를 줄이고 개인 경로를 검사했습니다.

[소스 변경 비교](https://github.com/VaderChen/FilmDevelop/compare/v1.26.0930-build-1745...v1.26.1002-build-1323) · [검증 기록](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md)

[Swift · 변경 기록 (繁體中文)](CHANGELOG.swift.md)
