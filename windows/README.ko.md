# Windows 치이카와 펫

[English](README.md) | [한국어](README.ko.md)

Windows 10/11용 C#·.NET 10·WPF 앱입니다. 공용 치이카와·하치와레·우사기·모몽가 스프라이트를 사용합니다.

## 설치

공통 [v1.1.4 릴리즈](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.1.4)에서 배포 파일을 받습니다.
단일 `SHA256SUMS`에 두 Windows 배포 파일과 두 macOS DMG의 체크섬을 함께 담습니다.
`ChiikawaPet-1.1.4-win-x64-setup.exe`를 실행하면 현재 사용자에게 설치하고
시작 메뉴 바로가기와 앱 제거 항목을 추가합니다. 관리자 권한은 필요하지 않습니다.
포터블 버전은 `ChiikawaPet-1.1.4-win-x64.zip`을 **모두 압축 해제**한 뒤
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

## 계정 연결

- Claude: Windows에 설치된 Claude Code에서 `/login`하세요. `%USERPROFILE%\.claude\.credentials.json`을 읽습니다.
- Codex: Windows 터미널에서 `codex login`하세요. `%USERPROFILE%\.codex\auth.json`의 ChatGPT OAuth 로그인을 읽습니다. API 키에는 구독 잔여 퍼센트가 없습니다.
- `CLAUDE_CONFIG_DIR`, `CODEX_HOME`을 설정한 셸에서 실행하면 해당 디렉터리를 사용합니다.
- WSL 로그인 파일은 자동으로 찾지 않습니다. 사용하려면 파일이 있는 Windows 접근 가능 디렉터리를 환경 변수로 지정하세요.
- Windows Credential Manager에만 저장된 로그인 정보는 지원하지 않습니다.
- 토큰이나 인증 파일을 갱신하지 않습니다. CLI에서 재인증한 뒤 패널을 새로고침하세요.

토큰은 해당 제공자의 HTTPS 사용량 엔드포인트에만 전송합니다. 리디렉션·쿠키를
사용하지 않으며 토큰을 로그에 출력하거나 저장하지 않습니다. 두 서비스는 동시에
조회하고 2분마다 갱신합니다. 실패한 이전 데이터는 패널에 표시하고 트레이 현재 잔여량과 표정 계산에서는 제외합니다.

## 빌드

.NET 10 SDK를 설치한 뒤 저장소 루트에서 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

루트 [VERSION](../VERSION)을 Windows와 macOS의 공통 버전으로 사용합니다.
로직 검사 후 `build\windows\win-x64`에 앱을, `build\release\windows\1.1.4`에 ZIP을 만듭니다.
ARM64 포터블 빌드는 `-Runtime win-arm64`를 추가하세요. x64 설치 프로그램은
NSIS를 설치한 뒤 다음 명령으로 만듭니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```

macOS·Linux에서의 크로스 빌드:

```sh
dotnet run --project windows/Checks/Checks.csproj -c Release
dotnet publish windows/ChiikawaPet.csproj -c Release -r win-x64 --self-contained true -o build/windows/win-x64
```

## 미리보기와 검증

기존 펫을 종료한 뒤 실행하세요. 미리보기에서는 사용량을 조회하지 않습니다.

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
CI에서는 설치된 EXE에도 일반 실행 입력 검사를 한 뒤 제거합니다.
외형·실제 계정 조회·혼합 DPI는 Windows에서 직접 확인해야 합니다.

## 라이선스

소스 코드와 문서는 MIT입니다. 배포본의 `LICENSE`, `ARTWORK-NOTICE.md`에서
캐릭터 이미지와 로고의 별도 권한 범위를 확인하세요.
.NET 런타임 라이선스 안내는 `licenses/`에 포함합니다.
