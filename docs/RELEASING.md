# Releases

[English](RELEASING.md) | [한국어](RELEASING.ko.md)

mac and Windows have independent versions and GitHub Releases.

| Platform | Version file | Tag | Workflow | Output |
|---|---|---|---|---|
| mac | `mac/VERSION` | `mac-v1.1.0` | [release-mac.yml](../.github/workflows/release-mac.yml) | `build/release/mac/1.1.0/` |
| Windows | `windows/VERSION` | `windows-v1.1.0` | [release-windows.yml](../.github/workflows/release-windows.yml) | `build/release/windows/1.1.0/` |

## Versioning

Use `MAJOR.MINOR.PATCH` in the relevant platform's version file. Add a matching
note in `docs/releases/<platform>-v<version>.md`, update `CHANGELOG.md`, and keep
both README languages current. Release one OS without changing the other OS's version.
The mac build stamps its version into Info.plist; the Windows project reads its
version for assembly and file metadata.

## Packages

Run from the repository root. mac requires Swift 6+ and Apple build tools.
Windows requires .NET 10 and NSIS. Package validation uses Python 3.11+.

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

Each OS release has its own `SHA256SUMS`. Packages include both documentation
languages, the MIT source-code license, and a separate artwork notice. Windows
packages also include .NET's runtime licenses.

## GitHub workflow

Manual runs build reviewable artifacts for one OS. Pushing a matching platform
tag runs only that OS's checks and packaging, then creates its draft release.
The tag's version must match its platform version file. Review the results and
assets, then publish the draft.

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

Private repository releases remain private. Current packages have no Apple
Developer ID notarization or Windows signing certificate. Windows CI checks
installation, preview startup, and uninstall; manually verify visual behavior,
real account refresh, and mixed-DPI monitors.
