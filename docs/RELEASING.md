# Releases

[English](RELEASING.md) | [한국어](RELEASING.ko.md)

macOS and Windows share one version, one tag, and one GitHub Release.

| Setting | Value |
|---|---|
| Canonical version | Root [VERSION](../VERSION), currently `1.1.6` |
| Tag | `vMAJOR.MINOR.PATCH`, currently `v1.1.6` |
| Workflow | [release.yml](../.github/workflows/release.yml) |
| Release notes | [releases/v1.1.6.md](releases/v1.1.6.md), English and Korean together |
| macOS build output | `build/release/mac/1.1.6/` |
| Windows build output | `build/release/windows/1.1.6/` |
| Combined CI artifacts | `release/`, containing four packages and one `SHA256SUMS` |

## Versioning

Set `MAJOR.MINOR.PATCH` only in the root `VERSION`. Both platforms read this
file for app metadata and package filenames; neither has a separate version.
Add `docs/releases/v<version>.md`, update `CHANGELOG.md`, and keep both README
languages current. The tag version must match `VERSION`.

Published platform-specific tags and historical release notes remain unchanged.

## Packages

Run from the repository root. mac requires Swift 6+ and Apple build tools; DMG
packaging also needs Python 3.10+. The script installs pinned `dmgbuild` dependencies
into `build/dmg-tools` and writes Finder layout metadata without launching Finder.
CI uses Python 3.12. Windows requires .NET 10 and NSIS. Package validation uses Python 3.11+.

```sh
./scripts/test.sh
./scripts/package-mac.sh arm64
./scripts/package-mac.sh x86_64
python3 scripts/check-release.py mac
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
.\scripts\test-installed-windows.ps1 -Installer .\build\release\windows\1.1.6\ChiikawaPet-1.1.6-win-x64-setup.exe
python scripts/check-release.py windows
```

The platform checks validate their local packages. For the release, collect
these four files into `release/` and run the combined check from the repository root:

| Platform | File |
|---|---|
| macOS, Apple Silicon | `ChiikawaPet-1.1.6-mac-arm64.dmg` |
| macOS, Intel | `ChiikawaPet-1.1.6-mac-x86_64.dmg` |
| Windows, x64 installer | `ChiikawaPet-1.1.6-win-x64-setup.exe` |
| Windows, x64 portable | `ChiikawaPet-1.1.6-win-x64.zip` |

```sh
python3 scripts/check-release.py all release
```

This validates all four packages and writes `release/SHA256SUMS`. Upload that
single combined checksum file, not the per-platform check outputs, to the
[v1.1.6 release](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.1.6)
alongside all four packages. Packages include both documentation languages,
the MIT source-code license, and a separate artwork notice. Windows packages
also include .NET's runtime licenses.

Mac packaging mounts the finished image and verifies the app signature, global
`/Applications` link, background, and Finder metadata. Before publishing, open the
CI-built DMG in Finder and check the full background, arrow, icon placement, and
unclipped instructions. Drag its app onto the Applications shortcut, then launch
`/Applications/ChiikawaPet.app`. Open the usage panel.
Verify the selected pet, all character
choices, language controls, and provider logos. Running `--usage` alone does not
load artwork and cannot detect a broken packaged resource-bundle lookup.

## GitHub workflow

The single `release.yml` workflow builds and checks both platforms. On a matching
`vMAJOR.MINOR.PATCH` tag, **both OS jobs must succeed** before artifact aggregation,
the combined package/checksum check, and creation of one **draft** GitHub Release.
An OS failure must not produce a partial release.

Inspect the artifacts, checksums, and combined release notes before deliberately
publishing the draft. Draft creation does not publish the release.

```sh
git tag -a v1.1.6 -m 'Chiikawa Agent Pet v1.1.6'
git push origin main
git push origin v1.1.6
```

Private repository releases remain private. The mac app is ad-hoc signed, not
Apple Developer ID signed or notarized; Windows packages have no code-signing
certificate. Windows CI drives actual install/uninstall wizards, finish-page app
launch, ordinary installed EXE input, preference/credential preservation, and `/S`
compatibility. Before publishing, inspect the `windows-installer-preview` artifact's
welcome, finish, uninstall-confirm and uninstall-finish screenshots for clipping
and correct artwork. CI does not establish real-account or mixed-DPI correctness.

With Hidden Bar 1.11.1 on macOS 27, run exactly
`/Applications/ChiikawaPet.app`. Copies launched from the DMG, `build/`, Downloads,
or `~/Applications` can be hidden even in the visible section.
