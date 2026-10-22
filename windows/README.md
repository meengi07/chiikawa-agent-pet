# Chiikawa Agent Pet for Windows

[English](README.md) | [한국어](README.ko.md)

A Windows 10/11 desktop pet built with C#, .NET 10, and WPF, using the shared
Chiikawa, Hachiware, Usagi, and Momonga sprites.

## Installation

Download Windows packages from the shared
[v1.3.0 release](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.3.0).
Its single `SHA256SUMS` covers the two Windows packages and both macOS DMGs.
Run `ChiikawaPet-1.3.0-win-x64-setup.exe` to install for the current user and add
Start-menu shortcuts and an uninstall entry. No administrator access is required.
The wizard has a cream/pastel theme, all four characters, and a matching app icon.
On Finish, leave **Launch Chiikawa Pet** checked to start immediately, or clear it
and launch later from the Start menu. Korean Windows uses Korean installer text;
other Windows UI languages use English. Uninstall preserves preferences and CLI sign-in files.
Alternatively, extract **all** files from `ChiikawaPet-1.3.0-win-x64.zip` and run
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

Closing the main pet window, including with Alt+F4, exits the app and releases its
single-instance lock. Start it again from the Start menu. Use the tray visibility
control to hide the pet without quitting.

Preview mode does not save preference changes. Uninstalling leaves preferences
and CLI credentials in their separate locations.

## App updates

Choose **Check for Updates…** from the tray or pet's right-click menu, then accept
the install prompt. The app downloads and verifies the newer stable release,
exits, applies it, and restarts. A failed startup restores the previous version.
The installed package uses the per-user installer; portable updates replace only
files in the app's managed inventory and preserve unrelated files in the directory.
Preferences and CLI sign-in files remain in their existing locations.

**Automatic Updates (every 6 hours)** is **off by default** and saved in settings.
Enable it for startup/six-hour checks and automatic installation/restart; turn it
off before installation to cancel automatic application. Previews never check or
download updates. In-app updates support x64 Windows only.
Keep `ChiikawaPet.Updater.exe` and `.chiikawa-managed-files.json` with the app.

Install 1.3.0 manually once when upgrading from 1.1.6 or earlier.
Pinned-key release signatures and SHA-256 authenticate updates; they are not a
Windows code-signing certificate and do not remove SmartScreen warnings.

## Accounts

- Claude: use `/login` in Windows-installed Claude Code. The pet reads `%USERPROFILE%\.claude\.credentials.json`.
- Codex: use `codex login` in a Windows terminal. The pet reads the ChatGPT OAuth login in `%USERPROFILE%\.codex\auth.json`. API-key billing has no subscription quota percentage.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` override these directories when the executable is launched from the shell that sets them.
- Add explicit Claude/Codex homes in the panel, including a Windows-accessible `\\wsl.localhost\<distribution>\...` directory. The app does not invoke `wsl.exe`, copy credentials, or discover WSL homes automatically; Windows may activate the chosen distribution when accessing its UNC path.
- Opt into Codex's classic keyring-rs Credential Manager storage in the panel. It reads only the configured home's `cli|<first 16 SHA256 characters>.Codex Auth` target and UTF-16LE blob; newer secret-store namespaces are not supported. Stored credentials are never modified.
- The pet does not renew tokens or write credential files. Reauthenticate in the CLI, then refresh the panel.

Tokens are sent only to the corresponding provider's HTTPS quota endpoint.
Redirects and cookies are disabled and tokens are not logged or saved.
Accounts refresh concurrently on the normal two-minute schedule; HTTP 429 applies
per-account cooldowns and respects `Retry-After`, including for manual refresh.
Last-good snapshots persist without tokens, return as stale, and cannot cross
verified account/reset boundaries. Stale data does not drive the pet or current tray values.

## Monitoring and system preferences

Use the panel's monitoring/settings controls to select the pet's account/window and
expression thresholds, choose and reorder tray metrics, switch compact/bar rendering,
and show reset countdowns or conservative pace estimates. The limiting window is
identified; character-picker previews remain cheerful.

Quota/pace notifications and saved-account discovery are **off by default**.
Notifications establish a first-reading/reset baseline and deduplicate crossings.
Discovery reads supported saved accounts without switching or refreshing them.
The panel also exposes launch-at-login and a recorded global panel shortcut;
registration failures are shown. Uninstall removes only the installed copy's own
startup entry. Before moving or deleting a portable copy, disable its startup option;
enable it again after moving to register the new path.

Opt-in local history reads only the chosen CLI home's logs. Totals are home-scoped,
not verified per-account bills. Provider-reported credits, token counts, custom-price
estimates, and subscription percentages stay separate. There are no bundled prices.
See [history limitations and the pricing JSON format](../README.md#local-history-credits-and-estimated-cost).
Copy sanitized diagnostics from the panel when reporting an issue; never attach
authentication files. Existing pet, language, and update preferences are preserved.

## Building

Install the .NET 10 SDK and Visual Studio C++ build tools with MSVC and a Windows SDK
for the native-AOT updater, then run from the repository root:

```powershell
.\scripts\build-windows.ps1
```

The root [VERSION](../VERSION) sets the version for both Windows and macOS.
The script runs logic checks and writes the app to `build\windows\win-x64` and
the ZIP to `build\release\windows\1.3.0`. ARM64 source builds require the matching
MSVC toolchain and `-Runtime win-arm64`; in-app updates are x64-only.
On Windows, the script generates installer BMPs and a multi-size ICO from the
existing sprites using built-in System.Drawing, then embeds that icon in the app.
Generated artwork stays in `build\windows-artwork`; no image tools or modules are needed.
To create the x64 installer, install NSIS and run:

```powershell
.\scripts\package-windows.ps1
```

Cross-compilation from macOS or Linux:

```sh
dotnet run --project windows/Checks/Checks.csproj -c Release
dotnet publish windows/ChiikawaPet.csproj -c Release -r win-x64 --self-contained true -o build/windows/win-x64
```

On macOS, run checks with `TMPDIR=/private/tmp/ dotnet run --project windows/Checks/Checks.csproj -c Release`.
The updater deliberately rejects symlinked app paths; the usual `/var` temp prefix is a macOS symlink.

Raw cross-compilation does not generate the native-AOT updater, Windows installer
artwork, or branded executable icon. Use the Windows scripts for complete release packages.

## Preview and validation

Quit the running pet before previewing. Preview mode performs no quota or update requests.

```powershell
.\build\windows\win-x64\ChiikawaPet.exe --preview 10 --show-usage
```

Logic checks use fixtures rather than real credentials. On an interactive Windows
desktop, quit the running pet and run the native UI smoke from the repository root:

```powershell
dotnet run --project checks/windows-ui/UiSmoke.csproj --configuration Release
dotnet run --project checks/windows-ui/UiSmoke.csproj --configuration Release -- --executable .\build\windows\win-x64\ChiikawaPet.exe
```

The first command checks native mouse click/drag, saved and reloaded coordinates,
capture loss, routed Space activation, hide/tray/show, native usage-window and pet
window close, process/mutex cleanup, and relaunch. The second launches the actual
EXE without preview, with animation and refresh enabled, and detects modal error
dialogs during click/drag, panel close, position saving, and process shutdown.
Both restore settings and avoid real credentials or quota requests.
On a clean Windows desktop, run the full installer check:

```powershell
.\scripts\test-installed-windows.ps1 -Installer .\build\release\windows\1.3.0\ChiikawaPet-1.3.0-win-x64-setup.exe
```

This drives the real install/uninstall wizards, checks finish-page launch, ordinary
installed EXE input, preference/credential preservation, mutex guards, and silent
`/S` compatibility. Rendered welcome/completion/removal screenshots are saved in
`build\windows-installer-smoke`; CI uploads them with the generated artwork as
`windows-installer-preview`. Inspect those images before publishing.
Real account refresh and mixed-DPI monitors still require manual Windows verification.

## License

Source code and documentation are MIT licensed. See `LICENSE` and
`ARTWORK-NOTICE.md` included with the package for the separate artwork scope.
.NET runtime license notices are included under `licenses/`.
