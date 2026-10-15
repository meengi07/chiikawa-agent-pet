# Chiikawa Agent Pet mac v1.1.1

## Changes

- Add Momonga alongside Chiikawa, Hachiware, and Usagi, with six expressions and blink animation.
- Add English (default) and Korean UI modes. Character, language, size, visibility, and wandering preferences persist across launches.
- Fix the source launcher to install/update and run `/Applications/ChiikawaPet.app`, preserving existing preferences. With Hidden Bar 1.11.1 on macOS 27, apps launched outside `/Applications` can disappear even when placed in the visible section.
- Fix packaged resource lookup so CI-built apps can load sprites and logos at startup.
- Assemble fresh app bundles and remove obsolete files during source-launcher updates, avoiding stale resources and invalid bundle signatures.

## Downloads

Requires macOS 14 or later. Quit the running pet before replacing it.

| File | CPU | Install |
|---|---|---|
| `ChiikawaPet-1.1.1-mac-arm64.dmg` | Apple Silicon | Open the DMG and drag the app to `/Applications`. |
| `ChiikawaPet-1.1.1-mac-x86_64.dmg` | Intel | Open the DMG and drag the app to `/Applications`. |
| `SHA256SUMS` | Both | Verify downloads with SHA-256. |

Run the installed copy, not the copy inside the DMG, Downloads, or `~/Applications`, when using Hidden Bar on macOS 27.

The app is ad-hoc signed; Apple Developer ID signing and notarization are not configured. Usage endpoints are not guaranteed stable public APIs. Source code is MIT licensed; character artwork and provider logos are excluded and have a separate notice in each package. This is an unofficial fan project, not affiliated with Chiikawa.

## 한국어

- 모몽가와 여섯 가지 표정·눈 깜빡임을 추가했습니다.
- 영어·한국어 UI와 언어 선택 저장을 지원합니다.
- 배포본이 시작 시 스프라이트·로고 리소스를 찾지 못하던 오류를 수정했습니다.
- 앱 번들을 새로 구성하고 소스 런처 업데이트 시 오래된 파일을 제거해 리소스와 서명이 섞이지 않게 했습니다.
- 소스 런처가 `/Applications`에 설치한 앱을 실행하도록 수정했습니다. 기존 설정은 유지합니다.
- macOS 27 + Hidden Bar 1.11.1에서는 다른 폴더에서 실행한 앱이 표시 영역에 있어도 숨겨질 수 있습니다. 실행 중인 펫을 종료하고 DMG의 앱을 `/Applications`로 옮긴 뒤 설치본을 실행하세요. `~/Applications`는 해당하지 않습니다.

Apple Silicon·Intel에 맞는 DMG를 선택하고 `SHA256SUMS`로 다운로드를 확인하세요. 공인 서명·공증은 아직 없으며, MIT 라이선스는 캐릭터 이미지와 서비스 로고에 적용되지 않습니다.
