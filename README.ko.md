# FilmDevelop

사진에 좋아하는 필름 느낌을 더해 보세요. 필름을 고르고 노출, 색감, 입자를 조절한 뒤 내보내면 됩니다.

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![FilmDevelop](demo.gif)

## 다운로드

[Mac 버전 다운로드](https://github.com/VaderChen/FilmDevelop/releases/latest) 후 DMG를 열고 앱을 응용 프로그램 폴더로 드래그하세요.

**Apple Silicon Mac, macOS 14 이상**에서 사용할 수 있습니다. 번체 중국어, 영어, 일본어, 한국어를 지원하며 설치 파일은 Apple 공증을 받았습니다.

## 무엇을 할 수 있나요?

- **원하는 분위기 고르기**: 컬러, 흑백, 영화용 필름과 GR 카메라 시뮬레이션을 선택하고 나만의 조정도 저장할 수 있습니다.
- **색감 다듬기**: 노출, 화이트 밸런스, 대비, 입자, 현상, 스캔을 직접 조절할 수 있습니다.
- **한 번에 정리하고 편집하기**: 별점과 분류로 사진을 정리하고 조정값을 복사해 여러 사진에 함께 적용할 수 있습니다.
- **화면 정리하기**: 자르기, 회전, 불필요한 물체 복구와 함께 테두리와 날짜도 넣을 수 있습니다.
- **AI 도움받기**: 모델을 다운로드하면 Mac에서 사진을 분석하고 조정을 도와줍니다. 사진은 업로드하지 않습니다.
- **완성한 사진 내보내기**: JPEG, PNG, WebP, TIFF를 지원하며 크기와 색 공간을 선택할 수 있습니다. 원본 사진은 덮어쓰지 않습니다.

## 네 단계로 시작하기

1. 폴더를 선택하고 사진을 엽니다.
2. 좋아하는 필름을 고르거나 원본에서 조정을 시작합니다.
3. 미리보기를 보며 조절하세요. 실행 취소와 원본 비교도 가능합니다.
4. 사진을 내보냅니다. 여러 장을 선택해도 각 사진의 조정을 유지한 채 함께 내보낼 수 있습니다.

사진과 편집 내용은 Mac에 저장됩니다. AI 모델은 처음에 다운로드가 필요하며 준비 후에는 오프라인으로 사용할 수 있습니다.

## 설정 팁

**시스템 기본 디코딩과 시스템 기본 가속**을 사용하세요. 내장 소프트웨어 디코딩과 Vulkan은 Windows 지원을 준비하는 테스트 모드입니다. Windows 설치 프로그램은 아직 제공하지 않습니다.

필름과 카메라 스타일은 시뮬레이션이며 제조사 기본 설정이나 LUT가 아닙니다. 사용법이 궁금하면 앱에서 기능 제목을 클릭해 설명을 확인하세요.

<details>
<summary>소스에서 실행하고 싶다면</summary>

전체 Xcode와 CMake, glslang, Vulkan headers/loader, MoltenVK가 필요합니다. 의존성은 [빌드 안내](Vendor/PhotoCompute/README.md#建置與部署)를 참고하세요.

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

</details>

## 라이선스

Copyright © 2026 VaderChen. [라이선스](LICENSE.ko.md)에 따라 무료로 사용, 수정, 공유할 수 있습니다. 상업적 판매 및 이 소프트웨어를 이용한 유료 서비스는 금지합니다. 자세한 내용은 [상업적 판매 정책](COMMERCIAL-LICENSE.md)을 참고하세요. 사진과 내보낸 작품에는 소프트웨어 라이선스가 적용되지 않습니다. 제삼자 구성 요소에는 [각자의 라이선스](THIRD_PARTY_NOTICES.md)가 적용됩니다.
