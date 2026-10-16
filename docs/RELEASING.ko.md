# 릴리즈

[English](RELEASING.md) | [한국어](RELEASING.ko.md)

macOS와 Windows는 하나의 버전·태그·GitHub Release를 함께 사용합니다.

| 항목 | 값 |
|---|---|
| 버전 기준 | 루트 [VERSION](../VERSION), 현재 `1.2.0` |
| 태그 | `vMAJOR.MINOR.PATCH`, 현재 `v1.2.0` |
| Workflow | [release.yml](../.github/workflows/release.yml) |
| 릴리즈 노트 | [releases/v1.2.0.md](releases/v1.2.0.md)에 영어·한국어 함께 작성 |
| macOS 빌드 경로 | `build/release/mac/1.2.0/` |
| Windows 빌드 경로 | `build/release/windows/1.2.0/` |
| CI 통합 배포 경로 | `release/`에 네 배포 파일, `SHA256SUMS`, `updates.json`, `updates.sig` |

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
CI는 Python 3.12를 사용합니다. Windows는 .NET 10, Native AOT 업데이터용
MSVC C++ 빌드 도구·Windows SDK와 NSIS, 패키지 검사는 Python 3.11 이상이 필요합니다.

```sh
./scripts/test.sh
./scripts/package-mac.sh arm64
./scripts/package-mac.sh x86_64
python3 scripts/check-release.py mac
```

```powershell
.\scripts\package-windows.ps1
.\scripts\test-installed-windows.ps1 -Installer .\build\release\windows\1.2.0\ChiikawaPet-1.2.0-win-x64-setup.exe
python scripts/check-release.py windows
```

OS별 검사는 각 빌드 경로의 파일을 확인합니다. 릴리즈를 만들 때는 아래 네 파일을
`release/`에 모은 뒤 저장소 루트에서 통합 검사를 실행합니다.

| 플랫폼 | 파일 |
|---|---|
| macOS, Apple Silicon | `ChiikawaPet-1.2.0-mac-arm64.dmg` |
| macOS, Intel | `ChiikawaPet-1.2.0-mac-x86_64.dmg` |
| Windows, x64 설치 프로그램 | `ChiikawaPet-1.2.0-win-x64-setup.exe` |
| Windows, x64 포터블 | `ChiikawaPet-1.2.0-win-x64.zip` |

```sh
python3 scripts/check-release.py all release
```

네 파일을 모두 검사하고 `release/SHA256SUMS`를 만듭니다.
[v1.2.0 릴리즈](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.2.0)에는
이 단일 통합 체크섬 파일, 네 배포 파일과 아래의 업데이트 서명 파일을 함께 올립니다.
배포본에 영한 문서, MIT 코드 라이선스, 별도 이미지 안내를 넣고
Windows에는 .NET 라이선스도 포함합니다.

mac 패키징은 완성된 DMG를 마운트해 앱 서명, 전역 `/Applications` 연결,
배경과 Finder 배치 정보를 검사합니다. 배포 전에는 CI에서 만든 DMG를 Finder에서
열어 배경·화살표·아이콘 위치와 안내 문구가 잘리지 않는지 확인하세요.
앱을 응용 프로그램 바로가기로 드래그한 뒤 `/Applications/ChiikawaPet.app`을 실행하고
사용량 패널을 여세요. 선택한 펫·캐릭터 목록·언어 선택·서비스 로고를 확인합니다.
`--usage`만 실행하면 이미지를 읽지 않으므로 배포본의 리소스 번들 검색 오류를 잡을 수 없습니다.

## 업데이트 서명

`prepare-release`가 네 배포 파일의 이름·공식 다운로드 URL·크기·SHA-256을
ECDSA P-256/SHA-256으로 서명합니다. `updates.sig`는 `updates.json`의 **원본 바이트**에
대한 DER 서명을 base64로 담습니다. 서명 후 JSON을 다시 정렬하거나 포맷하지 마세요.
두 앱과 Windows 네이티브 헬퍼에 루트 `UPDATE_PUBLIC_KEY`를 포함합니다.

저장소 secret **`UPDATE_SIGNING_PRIVATE_KEY`**에는 해당 공개키와 짝인 PEM EC 개인키를
설정합니다. 서명 작업에서만 사용하며 배포 파일이나 Git에 포함하지 않습니다.
별도의 보호된 백업을 유지하세요. 기존 앱은 현재 공개키를 고정하므로 일반 릴리즈마다
키를 새로 만들거나 교체하면 안 됩니다. 스크립트는 개인키·공개키 불일치를 거부합니다.

로컬에서는 개인키를 출력하지 않고 환경 변수에 설정한 뒤 실행합니다.

```sh
python3 scripts/sign-updates.py release
```

생성한 **두 파일을 수정 없이** 네 패키지와 `SHA256SUMS` 옆에 업로드하세요.
서명 누락·오류, 크기·해시 불일치, 사전 릴리즈와 구버전은 설치하지 않습니다.
업데이터는 인증 없는 공개 GitHub 릴리즈 다운로드를 사용하며 private 배포 파일은
지원하지 않습니다. 자체 서명은 Apple Developer ID·공증이나 Windows 공인 코드 서명을 대체하지 않습니다.

CI는 두 Mac 아키텍처와 Windows x64에서 서명한 실제 패키지를 적용합니다.
Mac은 버전을 `0.0.0`으로 바꾼 임시 복사본, Windows는 공개 1.1.6 설치형·포터블을
사용합니다. 교체·재실행, 시작 실패 시 복원, 잘못된 입력 거부, 설정·레지스트리 버전과
포터블 사용자 파일 보존을 확인합니다. Windows 검사는 현재 설치가 아닌 격리된 대화형
계정에서 실행하세요. 1.1.6 이하에서는 1.2.0을 한 번 직접 설치해야 업데이터를 사용할 수 있습니다.

## GitHub workflow

단일 `release.yml`이 두 OS를 빌드하고 검사합니다. `vMAJOR.MINOR.PATCH` 태그로
실행하면 두 OS 빌드, 통합 패키지 검사, 업데이트 서명과 세 실제 적용·복원 작업이
**모두 성공한 뒤에만** 하나의 GitHub Release **초안**을 만듭니다.
어느 단계든 실패하면 게시를 차단합니다.

배포 파일·체크섬·통합 릴리즈 노트를 직접 검토한 뒤 초안 게시 여부를 결정하세요.
초안 생성은 자동 게시가 아닙니다.

```sh
git tag -a v1.2.0 -m 'Chiikawa Agent Pet v1.2.0'
git push origin main
git push origin v1.2.0
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
