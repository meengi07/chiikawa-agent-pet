# macOS 치이카와 펫

[English](README.md) | [한국어](README.ko.md)

macOS 14 이상에서 실행하는 비공식 도트 펫입니다. Swift·AppKit·SwiftUI를 사용하며
Dock 아이콘 없이 메뉴바에서 제어합니다.

## 설치

공통 [v1.2.0 릴리즈](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.2.0)에서
Apple Silicon은 `ChiikawaPet-1.2.0-mac-arm64.dmg`,
Intel은 `ChiikawaPet-1.2.0-mac-x86_64.dmg`를 선택하세요.
단일 `SHA256SUMS`에 두 DMG와 두 Windows 배포 파일의 체크섬을 함께 담습니다.
DMG를 열고 화살표를 따라 왼쪽 `ChiikawaPet.app`을 오른쪽 응용 프로그램 폴더로
드래그한 뒤 `/Applications/ChiikawaPet.app`을 실행합니다.
설치 화면은 크림색 배경과 네 도트 캐릭터로 꾸몄으며 Retina 화면을 지원합니다.
직접 앱을 교체할 때는 실행 중인 펫을 먼저 종료하세요.

macOS 27에서 Hidden Bar 1.11.1을 사용한다면 `/Applications/ChiikawaPet.app`을 실행하세요.
이 버전의 숨김 API는 `~/Applications`를 포함한 다른 경로에서 실행한 앱을
표시 영역에 배치해도 숨길 수 있습니다.

현재 앱은 ad-hoc 서명이며 Apple Developer ID 공증은 없습니다. macOS가 차단하면
소스와 릴리즈 체크섬을 확인한 뒤 실행을 원할 경우 시스템 설정 → 개인정보 보호 및
보안 → 확인 없이 열기 옵션을 사용할 수 있습니다.

## 언어

기본 언어는 영어입니다. 사용량 패널이나 제어 메뉴에서 English 또는 한국어를 선택하세요.
바로 적용하며 다음 실행에도 선택을 유지합니다.

## 조작

- 펫 클릭으로 사용량 패널을 열고 닫으며, 드래그로 이동합니다.
- 펫 우클릭이나 메뉴바 항목 클릭으로 제어 메뉴를 엽니다.
- 패널에서 캐릭터 선택, 크기 40–120% 조절(기본 65%), 산책·표시 설정, 새로고침·종료를 합니다.
- 데스크톱 펫을 숨겨도 메뉴바는 유지됩니다.

메뉴바에는 캐릭터, 서비스 로고, 현재 잔여량을 표시합니다. Claude는 조회된 첫 두
한도를, Codex는 조회된 한도 중 최솟값을 표시합니다. 실패·미연결 서비스는 `—`입니다.

## 앱 업데이트

메뉴바나 펫 우클릭 메뉴에서 **업데이트 확인…**을 누르세요.
설치 안내에 동의하면 새 버전을 다운로드·검증하고 앱을 교체한 뒤 다시 실행합니다.
펫 설정과 CLI 로그인은 보존하며 새 앱이 시작하지 못하면 이전 앱을 복원합니다.
DMG 밖의 쓰기 가능한 위치여야 하며 `/Applications`를 권장합니다.

**자동 업데이트 (6시간마다)**는 **기본 꺼짐**이고 선택을 저장합니다.
켜면 시작할 때와 6시간마다 최신 정식 버전을 확인해 자동 설치·재실행합니다.
설치 전에 옵션을 끄면 자동 적용을 취소합니다. 미리보기에서는 조회·다운로드하지 않습니다.
고정한 릴리즈 공개키와 SHA-256으로 검증하지만 Apple Developer ID 서명·공증은 아닙니다.

1.1.6 이하에는 업데이터가 없으므로 1.2.0을 한 번 직접 설치해야 합니다.

## 계정 연결

Claude Code에서 `/login`하거나 Codex에서 `codex login`한 뒤 **새로고침**을 누르세요.
기본 CLI 인증 파일이나 해당 macOS 키체인을 읽습니다. Claude의 기본 키체인은
계정 전환을 반영하도록 매번 `/usr/bin/security`로 먼저 읽고, 실패하면 기존 조회로 전환합니다.
키체인이 잠겨 있거나 도구를 신뢰하지 않으면 인증 창이 뜰 수 있으며, 도구는 5초 뒤 중단합니다.
기존 키체인 조회와 Codex는 직접 새로고침할 때만 인증 창을 허용합니다.

`CLAUDE_CONFIG_DIR`, `CODEX_HOME`으로 커스텀 경로를 사용할 수 있습니다.
Finder는 셸 환경 변수를 상속하지 않으므로 설정한 터미널에서 설치 앱 내부 실행 파일을 실행하세요.

```sh
/Applications/ChiikawaPet.app/Contents/MacOS/ChiikawaPet
```

펫은 토큰을 갱신하거나 CLI 인증 파일·키체인을 수정하지 않습니다.
기존 CLI에서 재인증하세요. API 키 요금제에는 구독 잔여 퍼센트가 없습니다.

## 소스 빌드

Xcode 또는 Command Line Tools로 Swift 6 이상을 설치한 뒤 저장소 루트에서 실행합니다.
DMG 패키징에는 Python 3.10 이상도 필요합니다. 고정 버전 도구는 시스템 Python이 아닌
`build/dmg-tools` 가상 환경에 설치하며, 패키징할 때 Finder를 실행할 필요는 없습니다.

```sh
./Launch.command
./scripts/test.sh
./scripts/package-mac.sh arm64
```

`Launch.command`는 빌드 후 실행 중인 펫을 종료하고 `/Applications`에 설치하거나
업데이트한 뒤 해당 앱을 실행합니다. 빌드·패키징 스크립트만 실행하면 설치하지 않습니다.

루트 [VERSION](../VERSION)을 macOS와 Windows의 공통 버전으로 사용합니다.
Intel DMG는 `x86_64`를 지정합니다. 배포 파일은 `build/release/mac/1.2.0/`에 생성됩니다.
미리보기는 기존 앱을 종료한 뒤 실행하며 실제 사용량을 조회하지 않습니다.

```sh
open -n /Applications/ChiikawaPet.app --args --preview 10 --show-usage
```

소스 코드는 MIT입니다. 앱의 `Contents/Resources`에 영한 README, `LICENSE`,
캐릭터 이미지·로고의 별도 범위를 안내하는 `ARTWORK-NOTICE.md`를 포함합니다.
