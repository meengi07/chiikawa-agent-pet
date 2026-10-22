# Windows 치이카와 펫

[English](README.md) | [한국어](README.ko.md)

Windows 10/11용 C#·.NET 10·WPF 앱입니다. 공용 치이카와·하치와레·우사기·모몽가 스프라이트를 사용합니다.

## 설치

공통 [v1.3.0 릴리즈](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.3.0)에서 배포 파일을 받습니다.
단일 `SHA256SUMS`에 두 Windows 배포 파일과 두 macOS DMG의 체크섬을 함께 담습니다.
`ChiikawaPet-1.3.0-win-x64-setup.exe`를 실행하면 현재 사용자에게 설치하고
시작 메뉴 바로가기와 앱 제거 항목을 추가합니다. 관리자 권한은 필요하지 않습니다.
설치 화면은 크림색·파스텔 배경, 네 도트 캐릭터와 전용 앱 아이콘으로 꾸몄습니다.
완료 화면의 **Chiikawa Pet 실행**을 선택하면 바로 실행하고, 해제하면 시작 메뉴에서
나중에 실행할 수 있습니다. Windows 표시 언어가 한국어면 한국어, 그 외에는 영어로
안내합니다. 앱을 제거해도 펫 설정과 CLI 로그인 파일은 보존합니다.
포터블 버전은 `ChiikawaPet-1.3.0-win-x64.zip`을 **모두 압축 해제**한 뒤
`ChiikawaPet.exe`를 실행합니다. 두 배포본에는 .NET이 포함됩니다.
포터블 EXE를 DLL 등 다른 파일과 분리하지 마세요. 현재 공인 코드 서명은 없습니다.

펫은 화면 오른쪽 아래에 표시됩니다. 작업 표시줄 버튼은 없고 알림 영역 아이콘으로
제어합니다. Windows가 아이콘을 숨겼다면 `^` 안에서 찾으세요.

## 언어

기본 언어는 영어입니다. 사용량 패널이나 제어 메뉴에서 English 또는 한국어를 선택하세요.
바로 적용하며 다음 실행에도 선택을 유지합니다.

## 조작

| 조작 | 동작 |
|---|---|
| 펫 클릭 / 트레이 아이콘 왼쪽 클릭 | 사용량 패널 열기·닫기 |
| 펫 드래그 | 이동 및 위치 저장 |
| 펫 우클릭 / 트레이 아이콘 우클릭 | 캐릭터·표시·산책·새로고침·가운데 이동·종료 |
| 패널 | 캐릭터 선택, 크기 40–120% 조절(기본 65%), 설정 변경 |
| 패널 밖 클릭 / Escape / 닫기 | 패널 닫기 |

설정은 `%LOCALAPPDATA%\ChiikawaPet\settings.json`에 저장합니다. 시작할 때 저장된
위치가 현재 화면 밖이면 화면 안으로 옮깁니다. 펫을 숨기면 애니메이션은 멈추지만
트레이와 사용량 조회는 유지합니다. 미리보기에서는 설정을 저장하지 않습니다.
앱을 제거해도 별도 위치에 저장된 설정과 CLI 로그인 정보는 보존합니다.

펫 창에서 Alt+F4를 누르면 앱을 종료하고 실행 잠금을 해제합니다. 시작 메뉴에서
다시 실행할 수 있습니다. 종료하지 않고 숨기려면 트레이에서 화면에 펫 표시를 끄세요.

## 앱 업데이트

트레이 또는 펫 우클릭 메뉴에서 **업데이트 확인…**을 누르고 설치 안내에 동의하세요.
최신 정식 버전을 다운로드·검증한 뒤 종료하고 새 버전을 적용해 다시 실행합니다.
새 앱이 시작하지 못하면 이전 버전으로 복원합니다. 설치형은 현재 사용자 설치 프로그램을
사용하고, 포터블은 앱 관리 목록의 파일만 교체해 같은 폴더의 다른 사용자 파일을 보존합니다.
펫 설정과 CLI 로그인 파일은 원래 위치에 유지합니다.

**자동 업데이트 (6시간마다)**는 **기본 꺼짐**이며 설정에 저장합니다.
켜면 시작할 때와 6시간마다 확인해 자동 설치·재실행합니다. 설치 전에 끄면 자동 적용을
취소합니다. 미리보기에서는 조회·다운로드하지 않습니다. 앱 내부 업데이트는 Windows x64만
지원합니다. `ChiikawaPet.Updater.exe`와 `.chiikawa-managed-files.json`을 앱과 함께 유지하세요.

1.1.6 이하에서는 1.3.0을 한 번 직접 설치해야 합니다. 고정한 공개키의 릴리즈 서명과
SHA-256으로 검증하지만 Windows 코드 서명 인증서는 아니므로 SmartScreen 경고는 남습니다.

## 계정 연결

- Claude: Windows에 설치된 Claude Code에서 `/login`하세요. `%USERPROFILE%\.claude\.credentials.json`을 읽습니다.
- Codex: Windows 터미널에서 `codex login`하세요. `%USERPROFILE%\.codex\auth.json`의 ChatGPT OAuth 로그인을 읽습니다. API 키에는 구독 잔여 퍼센트가 없습니다.
- `CLAUDE_CONFIG_DIR`, `CODEX_HOME`을 설정한 셸에서 실행하면 해당 디렉터리를 사용합니다.
- 패널에서 Claude·Codex 홈을 직접 추가할 수 있습니다. WSL은 `\\wsl.localhost\<배포판>\...`처럼 Windows에서 접근할 수 있는 경로를 직접 지정합니다. 앱은 `wsl.exe` 실행·자동 검색·인증 복사를 하지 않지만 Windows가 UNC 경로 접근 시 선택한 배포판을 실행할 수 있습니다.
- 패널에서 Codex의 기존 keyring-rs Credential Manager 읽기를 켤 수 있습니다. 설정한 홈의 `cli|<SHA256 앞 16자리>.Codex Auth` 항목과 UTF-16LE 형식만 읽으며 새 secret-store 네임스페이스는 지원하지 않습니다. 저장된 인증은 수정하지 않습니다.
- 토큰이나 인증 파일을 갱신하지 않습니다. CLI에서 재인증한 뒤 패널을 새로고침하세요.

토큰은 해당 제공자의 HTTPS 사용량 엔드포인트에만 전송합니다. 리디렉션·쿠키를
사용하지 않으며 토큰을 로그에 출력하거나 저장하지 않습니다. 계정은 기본 2분 간격으로
동시에 조회합니다. HTTP 429의 계정별 `Retry-After` 대기는 수동 새로고침에도 적용합니다.
마지막 정상값은 토큰 없이 저장하고 이전 데이터로 복원합니다. 확인된 계정·초기화 구간을
넘어 재사용하지 않으며 이전 값은 현재 트레이 잔여량·표정 계산에서 제외합니다.

## 사용량·시스템 설정

패널에서 펫이 반응할 계정·한도와 표정 경계값을 선택합니다. 트레이 지표를 골라 순서를
바꾸고 간략·막대 표시, 초기화 카운트다운·사용 속도 추정을 설정합니다.
표정에 영향을 준 한도를 표시하며 캐릭터 선택 카드는 밝은 표정을 유지합니다.

잔여량·속도 알림과 저장 계정 검색은 **기본 꺼짐**입니다. 첫 조회·새 초기화 구간은
알림 기준값만 기록하며 같은 경고는 중복 발송하지 않습니다. 계정 검색은 저장소를 읽을 뿐
계정 전환이나 토큰 갱신은 하지 않습니다. 로그인 시 실행과 기록형 전역 패널 단축키도
설정하며 등록 실패는 화면에 알립니다. 설치형 제거 시 해당 설치본의 자동 실행 등록만
지웁니다. 포터블 앱을 옮기거나 지우기 전에는 자동 실행을 끄고, 옮긴 뒤 다시 켜서
새 경로를 등록하세요.

선택형 로컬 기록은 선택한 CLI 홈의 로그만 읽습니다. 계정별 청구 내역이 아닌 홈 단위
집계입니다. 추가 크레딧·토큰 수·사용자 단가 기반 추정 금액은 구독 잔여 퍼센트와 분리합니다.
내장 단가는 없습니다. [기록의 제한과 단가 JSON 형식](../README.ko.md#로컬-기록크레딧비용-추정)을
확인하세요. 문제 제보 시 패널에서 비밀 정보를 제거한 진단을 복사하고 인증 파일은
첨부하지 마세요. 기존 펫·언어·업데이트 설정은 유지합니다.

## 빌드

.NET 10 SDK와 Native AOT 업데이터용 Visual Studio C++ 빌드 도구(MSVC·Windows SDK)를
설치한 뒤 저장소 루트에서 실행합니다.

```powershell
.\scripts\build-windows.ps1
```

루트 [VERSION](../VERSION)을 Windows와 macOS의 공통 버전으로 사용합니다.
로직 검사 후 `build\windows\win-x64`에 앱을, `build\release\windows\1.3.0`에 ZIP을 만듭니다.
Windows 기본 System.Drawing으로 기존 스프라이트에서 설치 배경 BMP와 다중 크기 ICO를
만들고 앱에 아이콘을 넣습니다. 생성 이미지는 `build\windows-artwork`에 저장하며
별도 이미지 도구나 모듈은 필요하지 않습니다.
ARM64 소스 빌드는 해당 MSVC 도구와 `-Runtime win-arm64`가 필요하며 앱 내부 업데이트는
x64만 지원합니다. x64 설치 프로그램은 NSIS를 설치한 뒤 다음 명령으로 만듭니다.

```powershell
.\scripts\package-windows.ps1
```

macOS·Linux에서의 크로스 빌드:

```sh
dotnet run --project windows/Checks/Checks.csproj -c Release
dotnet publish windows/ChiikawaPet.csproj -c Release -r win-x64 --self-contained true -o build/windows/win-x64
```

macOS에서는 `TMPDIR=/private/tmp/ dotnet run --project windows/Checks/Checks.csproj -c Release`로 검사하세요.
업데이터는 심볼릭 링크가 포함된 앱 경로를 거부하며 macOS의 기본 `/var` 임시 경로는 심볼릭 링크입니다.

일반 크로스 빌드에서는 Native AOT 업데이터, Windows 설치 이미지, 전용 실행 파일
아이콘을 만들지 않습니다. 완전한 릴리즈 패키지는 Windows 빌드·패키징 스크립트로 만드세요.

## 미리보기와 검증

기존 펫을 종료한 뒤 실행하세요. 미리보기에서는 사용량이나 앱 업데이트를 조회하지 않습니다.

```powershell
.\build\windows\win-x64\ChiikawaPet.exe --preview 10 --show-usage
```

로직 검사는 실제 로그인 대신 고정된 예시 데이터를 사용합니다. 실제 Windows 데스크톱에서
기존 펫을 종료한 뒤 저장소 루트에서 UI 검사를 실행할 수 있습니다.

```powershell
dotnet run --project checks/windows-ui/UiSmoke.csproj --configuration Release
dotnet run --project checks/windows-ui/UiSmoke.csproj --configuration Release -- --executable .\build\windows\win-x64\ChiikawaPet.exe
```

첫 명령은 실제 클릭·드래그, 위치 저장·복원, 캡처 해제, WPF Space 입력,
숨김·트레이·표시, 사용량 창과 펫 창 닫기, 실행 잠금 해제와 재실행을 확인합니다.
두 번째는 실제 EXE를 미리보기 없이 실행합니다. 애니메이션과 자동 조회를 켠 채
클릭·드래그·창 닫기·위치 저장·종료를 검사하고 오류 대화상자도 실패로 판정합니다.
두 검사 모두 설정을 복원하고 실제 인증 정보나 사용량 API를 사용하지 않습니다.
기존 설치가 없는 Windows 데스크톱에서는 전체 설치 검사를 실행할 수 있습니다.

```powershell
.\scripts\test-installed-windows.ps1 -Installer .\build\release\windows\1.3.0\ChiikawaPet-1.3.0-win-x64-setup.exe
```

실제 설치·제거 화면, 완료 후 실행, 설치된 EXE의 일반 입력, 설정·인증 파일 보존,
실행 중 설치 방지와 `/S` 무인 설치 호환성을 확인합니다. 실제 화면 캡처는
`build\windows-installer-smoke`에 저장합니다. CI의 `windows-installer-preview`
아티팩트에는 이 캡처와 생성 이미지를 담으므로 배포 전에 확인하세요.
실제 계정 조회와 혼합 DPI는 Windows에서 별도로 확인해야 합니다.

## 라이선스

소스 코드와 문서는 MIT입니다. 배포본의 `LICENSE`, `ARTWORK-NOTICE.md`에서
캐릭터 이미지와 로고의 별도 권한 범위를 확인하세요.
.NET 런타임 라이선스 안내는 `licenses/`에 포함합니다.
