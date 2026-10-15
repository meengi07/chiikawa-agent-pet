# Chiikawa Agent Pet for Windows

[English](README.md) | [한국어](README.ko.md)

A Windows 10/11 desktop pet built with C#, .NET 10, and WPF, using the shared
Chiikawa, Hachiware, Usagi, and Momonga sprites.

## Installation

Run `ChiikawaPet-1.1.0-win-x64-setup.exe` to install for the current user and add
Start-menu shortcuts and an uninstall entry. No administrator access is required.
Alternatively, extract **all** files from `ChiikawaPet-1.1.0-win-x64.zip` and run
`ChiikawaPet.exe`. Both packages include .NET; do not move the portable EXE away
from its DLLs and other files. Packages currently have no code-signing certificate.

The pet appears near the bottom-right of the screen. It has no taskbar button;
use its notification-area icon, including the `^` overflow if Windows hides it.

## Language

English is the default. Choose English or 한국어 in the usage panel or control menu.
The choice is applied immediately and saved for the next launch.

## Controls

| Action | Result |
|---|---|
| Click the pet or left-click its tray icon | Toggle the usage panel |
| Drag the pet | Move it and save the position |
| Right-click the pet or its tray icon | Open character, visibility, wandering, refresh, recenter, and quit controls |
| Use the panel | Select a character, set size from 40% to 120% (default 65%), or change settings |
| Click outside the panel, press Escape, or select Close | Close the panel |

Preferences are stored in `%LOCALAPPDATA%\ChiikawaPet\settings.json`.
Saved positions are clamped onto the current monitor layout at startup.
Hiding the pet stops animation while retaining tray controls and quota refresh.
Preview mode does not save preference changes. Uninstalling leaves preferences
and CLI credentials in their separate locations.

## Accounts

- Claude: use `/login` in Windows-installed Claude Code. The pet reads `%USERPROFILE%\.claude\.credentials.json`.
- Codex: use `codex login` in a Windows terminal. The pet reads the ChatGPT OAuth login in `%USERPROFILE%\.codex\auth.json`. API-key billing has no subscription quota percentage.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` override these directories when the executable is launched from the shell that sets them.
- WSL credentials are not discovered automatically. To use them, set an override to a Windows-accessible directory containing the credential file.
- Windows Credential Manager-only storage is not supported.
- The pet does not renew tokens or write credential files. Reauthenticate in the CLI, then refresh the panel.

Tokens are sent only to the corresponding provider's HTTPS quota endpoint.
Redirects and cookies are disabled and tokens are not logged or saved.
Both providers are queried concurrently and refreshed every two minutes.
Failed readings remain labeled stale in the panel and are excluded from current
tray values and the expression calculation.

## Building

Install the .NET 10 SDK and run these commands from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

The script runs logic checks and writes the app to `build\windows\win-x64` and
the ZIP to `build\release\windows\1.1.0`. Use `-Runtime win-arm64` for an ARM64 portable build.
To create the x64 installer, install NSIS and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```

Cross-compilation from macOS or Linux:

```sh
dotnet run --project windows/Checks/Checks.csproj -c Release
dotnet publish windows/ChiikawaPet.csproj -c Release -r win-x64 --self-contained true -o build/windows/win-x64
```

## Preview and validation

Quit the running pet before previewing. Preview mode performs no quota requests.

```powershell
.\build\windows\win-x64\ChiikawaPet.exe --preview 10 --show-usage
```

Logic checks use fixtures rather than real credentials. Validate transparency,
animation, click-versus-drag behavior, tray restoration, real account refresh,
mixed-DPI monitors, preference restoration, and install/uninstall on Windows.

## License

Source code and documentation are MIT licensed. See `LICENSE` and
`ARTWORK-NOTICE.md` included with the package for the separate artwork scope.
.NET runtime license notices are included under `licenses/`.
