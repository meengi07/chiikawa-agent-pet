# 릴리즈

[English](RELEASING.md) | [한국어](RELEASING.ko.md)

macOS와 Windows는 하나의 버전·태그·GitHub Release를 함께 사용합니다.

| 항목 | 값 |
|---|---|
| 버전 기준 | 루트 [VERSION](../VERSION), 현재 `1.1.5` |
| 태그 | `vMAJOR.MINOR.PATCH`, 현재 `v1.1.5` |
| Workflow | [release.yml](../.github/workflows/release.yml) |
| 릴리즈 노트 | [releases/v1.1.5.md](releases/v1.1.5.md)에 영어·한국어 함께 작성 |
| macOS 빌드 경로 | `build/release/mac/1.1.5/` |
| Windows 빌드 경로 | `build/release/windows/1.1.5/` |
| CI 통합 배포 경로 | `release/`에 네 배포 파일과 단일 `SHA256SUMS` |

## 버전 관리

루트 `VERSION` 하나에만 `MAJOR.MINOR.PATCH`를 기록합니다.
두 OS가 이 파일을 읽어 앱 메타데이터와 배포 파일 이름에 같은 버전을 사용합니다.
`docs/releases/v<버전>.md`에 릴리즈 노트를 추가하고 `CHANGELOG.md`와
영어·한국어 README를 갱신하세요. 태그 버전은 `VERSION`과 일치해야 합니다.

이미 게시한 OS별 태그와 과거 릴리즈 노트는 변경하지 않습니다.

## 패키징

저장소 루트에서 실행합니다. mac은 Swift 6 이상과 Apple 개발 도구가 필요하며,
DMG 패키징에는 Python 3.10 이상도 필요합니다. 스크립트는 고정 버전 `dmgbuild`
의존성을 `build/dmg-tools`에 설치하고 Finder 실행 없이 배치 정보를 기록합니다.
CI는 Python 3.12를 사용합니다. Windows는 .NET 10과 NSIS,
패키지 검사는 Python 3.11 이상이 필요합니다.

```sh
./scripts/test.sh
./scripts/package-mac.sh arm64
./scripts/package-mac.sh x86_64
python3 scripts/check-release.py mac
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
.\scripts\test-installed-windows.ps1 -Installer .\build\release\windows\1.1.5\ChiikawaPet-1.1.5-win-x64-setup.exe
python scripts/check-release.py windows
```

OS별 검사는 각 빌드 경로의 파일을 확인합니다. 릴리즈를 만들 때는 아래 네 파일을
`release/`에 모은 뒤 저장소 루트에서 통합 검사를 실행합니다.

| 플랫폼 | 파일 |
|---|---|
| macOS, Apple Silicon | `ChiikawaPet-1.1.5-mac-arm64.dmg` |
| macOS, Intel | `ChiikawaPet-1.1.5-mac-x86_64.dmg` |
| Windows, x64 설치 프로그램 | `ChiikawaPet-1.1.5-win-x64-setup.exe` |
| Windows, x64 포터블 | `ChiikawaPet-1.1.5-win-x64.zip` |

```sh
python3 scripts/check-release.py all release
```

네 파일을 모두 검사하고 `release/SHA256SUMS`를 만듭니다.
[v1.1.5 릴리즈](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.1.5)에는
OS별 검사 결과가 아니라 이 단일 통합 체크섬 파일과 네 배포 파일을 함께 올립니다.
배포본에 영한 문서, MIT 코드 라이선스, 별도 이미지 안내를 넣고
Windows에는 .NET 라이선스도 포함합니다.

mac 패키징은 완성된 DMG를 마운트해 앱 서명, 전역 `/Applications` 연결,
배경과 Finder 배치 정보를 검사합니다. 배포 전에는 CI에서 만든 DMG를 Finder에서
열어 배경·화살표·아이콘 위치와 안내 문구가 잘리지 않는지 확인하세요.
앱을 응용 프로그램 바로가기로 드래그한 뒤 `/Applications/ChiikawaPet.app`을 실행하고
사용량 패널을 여세요. 선택한 펫·캐릭터 목록·언어 선택·서비스 로고를 확인합니다.
`--usage`만 실행하면 이미지를 읽지 않으므로 배포본의 리소스 번들 검색 오류를 잡을 수 없습니다.

## GitHub workflow

단일 `release.yml`이 두 OS를 빌드하고 검사합니다. `vMAJOR.MINOR.PATCH` 태그로
실행하면 **두 OS 작업이 모두 성공한 뒤에만** 파일을 모아 통합 패키지·체크섬 검사를
거쳐 하나의 GitHub Release **초안**을 만듭니다.
한 OS가 실패하면 일부 파일만 담은 릴리즈를 만들지 않습니다.

배포 파일·체크섬·통합 릴리즈 노트를 직접 검토한 뒤 초안 게시 여부를 결정하세요.
초안 생성은 자동 게시가 아닙니다.

```sh
git tag -a v1.1.5 -m 'Chiikawa Agent Pet v1.1.5'
git push origin main
git push origin v1.1.5
```

Private 저장소의 릴리즈는 계속 비공개입니다. mac 앱은 ad-hoc 서명이며
Apple Developer ID 서명·공증은 없습니다. Windows 공인 코드 서명도 없습니다.
Windows CI는 실제 설치·제거 화면, 완료 후 펫 실행, 설치된 EXE의 일반 입력,
설정·인증 파일 보존과 `/S` 호환성을 검사합니다. 배포 전 `windows-installer-preview`
아티팩트의 시작·완료·제거 확인·제거 완료 캡처를 열어 문구 잘림과 이미지 배치를 확인하세요.
이 검사가 실제 계정 조회나 혼합 DPI까지 보장하지는 않습니다.

macOS 27 + Hidden Bar 1.11.1에서는 정확히 `/Applications/ChiikawaPet.app`을
실행해야 합니다. DMG 내부, `build/`, 다운로드 폴더, `~/Applications`에서 실행하면
표시 영역에 배치해도 숨겨질 수 있습니다.
