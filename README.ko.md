# Chiikawa Agent Pet · 치이카와 펫

[English](README.md) | [한국어](README.ko.md)

macOS와 Windows에서 화면 위에 떠다니는 비공식 도트 펫입니다.
치이카와·하치와레·우사기·모몽가를 선택하고 Claude·Codex 구독 잔여량을 확인하세요.
펫의 표정은 정상 조회된 한도 중 가장 낮은 잔여량에 따라 바뀝니다.

## 화면 미리보기

| 캐릭터 선택과 애니메이션 | 사용량 패널 |
|---|---|
| <img src="docs/images/mac-demo.gif" width="320" alt="치이카와·하치와레·우사기를 선택하는 실제 mac 앱 화면 GIF"> | <img src="docs/images/mac-usage.png" width="320" alt="캐릭터 설정과 Claude·Codex 예시 잔여량을 보여주는 mac 사용량 패널"> |

미리보기 모드에서 촬영한 실제 mac 앱 화면입니다. 표시된 퍼센트는
예시 데이터이며 실제 계정 사용량이 아닙니다.

<details>
<summary>모몽가와 네 캐릭터 선택</summary>

<img src="docs/images/mac-momonga.png" width="320" alt="꼬리와 발 전체가 보이는 모몽가와 네 캐릭터 선택 화면">

</details>

## 주요 기능

- 일반 창 위에 표시되는 투명한 애니메이션 펫
- 캐릭터 선택, 드래그 이동, 산책, 설정 저장
- 크기 40–120% 조절, 기본값 65%
- 기간별 잔여량·초기화 시각, 수동 새로고침, 2분마다 자동 조회
- 펫을 숨겨도 사용할 수 있는 macOS 메뉴바와 Windows 트레이
- 별도 계정이나 서버 없이 기존 Claude Code·Codex 로그인 연결

기본 언어는 영어입니다. 사용량 패널이나 메뉴의 **English / 한국어**에서
언어를 선택하면 다음 실행에도 유지됩니다. Windows 화면 동작은 아직 실험 단계이며
[알려진 제한 사항](#개인정보와-알려진-제한-사항)을 확인하세요.

## 설치

macOS와 Windows 배포 파일은 하나의 [v1.1.6 릴리즈](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.1.6)에서 받습니다.
두 OS 모두 공통 버전 `1.1.6`을 사용하며, 릴리즈의 단일 `SHA256SUMS`에 아래 네 파일의 체크섬을 담습니다.

| 플랫폼 | 배포 파일 | 설치 방법 |
|---|---|---|
| macOS 14 이상, Apple Silicon | `ChiikawaPet-1.1.6-mac-arm64.dmg` | DMG를 열고 앱을 오른쪽 응용 프로그램 폴더로 드래그합니다. |
| macOS 14 이상, Intel | `ChiikawaPet-1.1.6-mac-x86_64.dmg` | DMG를 열고 앱을 오른쪽 응용 프로그램 폴더로 드래그합니다. |
| Windows 10/11, x64 | `ChiikawaPet-1.1.6-win-x64-setup.exe` | 캐릭터 설치 화면의 안내를 따르고, 완료 화면이나 시작 메뉴에서 펫을 실행합니다. |
| Windows 10/11, x64 | `ChiikawaPet-1.1.6-win-x64.zip` | **모든 파일을 압축 해제**한 뒤 `ChiikawaPet.exe`를 실행합니다. |

Windows 배포본에는 .NET이 포함됩니다. 설치 프로그램은 현재 사용자의
`%LOCALAPPDATA%\Programs\ChiikawaPet`에 설치하고 앱 제거 항목을 추가합니다.
포터블 EXE는 함께 압축 해제한 파일들과 같은 폴더에 있어야 합니다.

현재 배포본에는 Apple Developer ID 서명이나 Windows 코드 서명 인증서가 없습니다.
OS가 다운로드한 앱을 차단하면 소스와 릴리즈 체크섬을 확인한 뒤 OS에서 제공하는
열기·실행 옵션을 사용하세요.

## 계정 연결

1. Claude Code에서 `/login`하거나 Codex에서 `codex login`으로 로그인합니다.
2. 펫을 실행하고 클릭해서 사용량 패널을 연 뒤 **새로고침**을 누릅니다.

API 키 요금제는 구독 잔여 퍼센트를 제공하지 않습니다.

| 플랫폼 | Claude 로그인 정보 | Codex 로그인 정보 |
|---|---|---|
| macOS | `~/.claude/.credentials.json` 또는 `Claude Code-credentials` 키체인 | `~/.codex/auth.json` 또는 설정 경로에 연결된 `Codex Auth` 키체인 |
| Windows | `%USERPROFILE%\.claude\.credentials.json` | `%USERPROFILE%\.codex\auth.json` |

macOS의 Claude 키체인은 매번 `/usr/bin/security`로 현재 계정을 먼저 읽고, 실패하면
기존 키체인 조회로 전환합니다. 키체인이 잠겨 있거나 `security`를 신뢰하지 않으면
인증 창이 뜰 수 있으며, 도구가 5초 안에 끝나지 않으면 중단합니다.
기존 키체인 조회와 Codex는 직접 새로고침할 때만 인증 창을 허용합니다.
Windows Credential Manager에만 저장된 계정은 지원하지 않습니다.
WSL 내부 로그인은 자동으로 찾지 않으며 [Windows 안내](windows/README.ko.md)를 참고하세요.

`CLAUDE_CONFIG_DIR`, `CODEX_HOME`으로 기본 경로를 바꿀 수 있습니다. 해당 환경 변수를
설정한 터미널에서 앱을 실행하세요. Finder에서 실행한 앱은 셸 환경 변수를 상속하지
않으므로 커스텀 경로를 사용할 때는 앱 내부 실행 파일을 직접 실행합니다.
인증이 만료되면 기존 CLI에서 갱신해야 합니다. 펫은 토큰을 갱신하거나 인증 파일·키체인을 수정하지 않습니다.

## 사용법

| 조작 | 동작 |
|---|---|
| 펫 클릭 | 사용량 패널 열기·닫기 |
| 펫 드래그 | 이동 및 위치 저장 |
| 펫 우클릭 | 제어 메뉴 열기 |
| macOS 메뉴바 항목 클릭 | 제어 메뉴 열기 |
| Windows 트레이 아이콘 왼쪽·오른쪽 클릭 | 패널 열기·닫기 / 제어 메뉴 열기 |
| 사용량 패널 | 캐릭터·크기·산책·표시 설정, 새로고침, 종료 |

macOS에는 Dock 아이콘이 없습니다. Windows에는 작업 표시줄 버튼이 없으며,
트레이 아이콘이 숨겨졌다면 알림 영역의 `^`를 확인하세요. 펫을 숨겨도 메뉴바·트레이는
유지되고 애니메이션은 멈춥니다. 마우스가 펫 가까이에 있거나 패널이 열리면 산책을 멈춥니다.

### 잔여량과 표정

잔여량은 `max(0, 100 − 사용률)`입니다. 사용률이 100%를 넘더라도 잔여 0%와
울먹 표정을 유지합니다. 음수와 유한하지 않은 사용률은 오류로 처리합니다.
정상 조회된 서비스의 한도 중 최솟값을 사용하며 합산하거나 평균을 내지 않습니다.
정수 표시는 내림하고 표정 경계는 원래 소수 퍼센트로 판정합니다.

| 잔여량 | 표정 |
|---|---|
| 95–100% | 활짝 웃음 |
| 60% 이상, 95% 미만 | 미소 |
| 30% 이상, 60% 미만 | 걱정 |
| 10% 초과, 30% 미만 | 울상 |
| 0–10%, 정확히 10% 포함 | 울음 |
| 유효한 조회값 없음 | 미연결, 0%로 취급하지 않음 |

실제로 제공된 한도만 표시합니다. 조회 실패한 서비스는 표정과 메뉴바·트레이의 현재
잔여량에서 제외합니다. 이전 조회값은 패널에 오류와 이전 데이터 표시를 붙여 남길 수 있습니다.

## 개발

저장소를 복제한 뒤 루트에서 명령을 실행하세요.

```sh
git clone https://github.com/meengi07/chiikawa-agent-pet.git
cd chiikawa-agent-pet
```

| 플랫폼 | 기술스택 | 소스 빌드 요구사항 |
|---|---|---|
| macOS | Swift, AppKit, SwiftUI | macOS 14 이상, Swift 6 이상, Xcode 또는 Command Line Tools |
| Windows | C#, .NET 10, WPF, Windows Forms 트레이 | .NET 10 SDK, 설치 프로그램 생성 시 NSIS |

### macOS

개발 도구가 없으면 `xcode-select --install`로 설치한 뒤 실행합니다.

```sh
./Launch.command
./scripts/test.sh
```

`Launch.command`는 앱을 빌드하고 실행 중인 펫을 종료한 뒤
`/Applications/ChiikawaPet.app`에 설치하거나 업데이트하고 해당 앱을 실행합니다.
`test.sh`는 전체 Xcode 없이 Command Line Tools만 설치된 환경도 지원합니다.

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

로직 검사 후 런타임을 포함한 앱과 포터블 ZIP을 만듭니다. ARM64 포터블 빌드는
`-Runtime win-arm64`를 추가하세요. x64 설치 프로그램은 [NSIS](https://nsis.sourceforge.io/Download)를
설치한 뒤 다음 명령으로 만듭니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```

macOS·Linux에서도 Windows 대상으로 컴파일할 수 있습니다.

```sh
dotnet run --project windows/Checks/Checks.csproj -c Release
dotnet publish windows/ChiikawaPet.csproj -c Release -r win-x64 --self-contained true -o build/windows/win-x64
```

### 프로젝트 구조

```text
mac/       Swift 소스·테스트·앱 정보
windows/     C# 소스·로직 검사·설치 프로그램 정의
assets/      공용 스프라이트와 서비스 로고
scripts/     빌드·검사·패키징·릴리즈 검증
docs/        릴리즈 안내와 변경 사항
VERSION      두 OS의 공통 MAJOR.MINOR.PATCH 버전
```

OS별 코드는 분리하고 두 앱 모두 `assets/`의 같은 PNG를 포함합니다.
스프라이트 시트는 8열·6개 표정 행이며 각 프레임은 64×80 픽셀입니다.

### 표정 미리보기

기존 펫을 종료한 뒤 실행하세요. 미리보기에서는 실제 계정 사용량을 조회하지 않습니다.

```sh
open -n /Applications/ChiikawaPet.app --args --preview 10 --show-usage
```

```powershell
.\build\windows\win-x64\ChiikawaPet.exe --preview 10 --show-usage
```

## 릴리즈와 버전 관리

루트 [VERSION](VERSION) 하나를 기준으로 두 앱의 버전과 배포 파일 이름을 맞춥니다.
[릴리즈 안내](docs/RELEASING.ko.md)와 [변경 기록](CHANGELOG.md)을 확인하세요.
공통 [.github/workflows/release.yml](.github/workflows/release.yml)이 `vMAJOR.MINOR.PATCH`
태그로 두 OS를 빌드합니다. 두 OS 작업이 모두 성공해야 네 배포 파일과 단일
`SHA256SUMS`를 담은 GitHub Release **초안**을 만듭니다.
배포 파일을 직접 검토한 뒤 초안 게시 여부를 결정합니다.

## 개인정보와 알려진 제한 사항

- 기존 토큰은 각 제공자의 HTTPS 사용량 엔드포인트에만 전송합니다. 별도 서버, 브라우저 쿠키 수집, 토큰 로그·저장 기능은 없습니다.
- 사용량 엔드포인트는 관측된 인터페이스이며 안정성이 보장된 공개 API가 아닙니다. 제공자 변경으로 연동이 깨질 수 있습니다.
- Windows 화면·설치 프로그램 실행·혼합 DPI는 Windows에서 확인해야 합니다. 크로스 빌드와 로직 검사가 화면의 정확성까지 보장하지 않습니다.
- macOS 27에서 Hidden Bar 1.11.1을 사용하면 `/Applications`에 설치한 앱을 실행해야 합니다. `build/`, 다운로드 폴더, `~/Applications`에서 실행하면 화살표 오른쪽에 배치해도 숨겨질 수 있습니다. `Launch.command`는 필요한 위치에 설치한 뒤 실행합니다.
- 공인 서명과 공증은 설정하지 않았습니다. 설치 파일 생성과 소스 코드 라이선스는 외부 이미지 사용 권한을 부여하지 않습니다.

## 기여

버그 제보와 PR을 받습니다. OS·CPU 종류, 재현 방법, 관련 오류를 포함하세요.
토큰이나 인증 파일은 포함하지 마세요. 변경한 플랫폼의 검사를 실행하고
공용 이미지는 `assets/`에서 관리합니다. 문서 변경 시 영어와 한국어를 함께 갱신하세요.

## 라이선스와 출처

소스 코드·스크립트·문서는 [MIT 라이선스](LICENSE)입니다.
캐릭터 이미지와 서비스 로고는 **제외**하며 [이미지 안내](assets/NOTICE.md)를 확인하세요.
Windows 배포본의 .NET 구성 요소 라이선스는 `licenses/`에 별도로 포함합니다.
스프라이트는 제공된 도트 레퍼런스에서 파생되었습니다.
치이카와 원작·브랜드와 제휴하지 않은 비공식 프로젝트입니다.
