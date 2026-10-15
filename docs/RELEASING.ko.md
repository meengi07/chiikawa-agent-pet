# 릴리즈

[English](RELEASING.md) | [한국어](RELEASING.ko.md)

mac과 Windows 버전 및 GitHub Release를 독립적으로 관리합니다.

| 플랫폼 | 버전 파일 | 태그 | Workflow | 배포 경로 |
|---|---|---|---|---|
| mac | `mac/VERSION` | `mac-v1.1.0` | [release-mac.yml](../.github/workflows/release-mac.yml) | `build/release/mac/1.1.0/` |
| Windows | `windows/VERSION` | `windows-v1.1.0` | [release-windows.yml](../.github/workflows/release-windows.yml) | `build/release/windows/1.1.0/` |

## 버전 관리

해당 OS의 버전 파일을 `MAJOR.MINOR.PATCH`로 관리합니다.
`docs/releases/<플랫폼>-v<버전>.md`에 릴리즈 노트를 추가하고 `CHANGELOG.md`와
영어·한국어 README를 갱신하세요. 한 OS를 배포할 때 다른 OS 버전은 올릴 필요가 없습니다.
mac은 Info.plist에 버전을 넣고 Windows 프로젝트는 어셈블리·파일 버전으로 읽습니다.

## 패키징

저장소 루트에서 실행합니다. mac은 Swift 6 이상과 Apple 개발 도구,
Windows는 .NET 10과 NSIS가 필요합니다. 패키지 검사는 Python 3.11 이상을 사용합니다.

```sh
./scripts/test.sh
./scripts/package-mac.sh arm64
./scripts/package-mac.sh x86_64
python3 scripts/check-release.py mac
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
.\scripts\test-installed-windows.ps1 -Installer .\build\release\windows\1.1.0\ChiikawaPet-1.1.0-win-x64-setup.exe
python scripts/check-release.py windows
```

각 OS의 릴리즈에 독립된 `SHA256SUMS`를 만듭니다. 배포본에 영한 문서,
MIT 코드 라이선스, 별도 이미지 안내를 넣고 Windows에는 .NET 라이선스도 포함합니다.

## GitHub workflow

수동 실행은 선택한 OS의 검토용 파일을 빌드합니다. 플랫폼 태그를 푸시하면 해당 OS의
검사·패키징만 실행하고 릴리즈 초안을 만듭니다. 태그 버전은 해당 버전 파일과 일치해야 합니다.
결과와 파일을 확인한 뒤 초안을 게시하세요.

```sh
git tag -a mac-v1.1.0 -m 'Chiikawa Agent Pet mac v1.1.0'
git push origin main
git push origin mac-v1.1.0
```

```sh
git tag -a windows-v1.1.0 -m 'Chiikawa Agent Pet Windows v1.1.0'
git push origin main
git push origin windows-v1.1.0
```

Private 저장소의 릴리즈는 계속 비공개입니다. 현재 Apple Developer ID 공증과
Windows 공인 서명은 없습니다. Windows CI는 설치·미리보기 시작·제거를 검사하며,
실제 화면·계정 조회·혼합 DPI는 직접 확인해야 합니다.
