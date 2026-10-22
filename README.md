# Chiikawa Agent Pet

[English](README.md) | [한국어](README.ko.md)

An unofficial pixel-art desktop companion for macOS and Windows. Choose Chiikawa,
Hachiware, Usagi, or Momonga and check your remaining Claude and Codex subscription quotas.
By default, your pet reacts to the lowest current quota. You can choose its account,
quota window, expression thresholds, and whether to use the estimated pace instead.

## Preview

| Character selection and animation | Usage panel |
|---|---|
| <img src="docs/images/mac-demo.gif" width="320" alt="macOS UI recording showing Chiikawa, Hachiware, and Usagi selection"> | <img src="docs/images/mac-usage.png" width="320" alt="macOS usage panel with character controls and simulated Claude and Codex quotas"> |

Real macOS UI captures using preview mode and simulated quotas. The app's
captures show Korean mode; the displayed percentages are demo values.

<details>
<summary>Momonga and four-character selection</summary>

<img src="docs/images/mac-momonga.png" width="320" alt="English mac UI showing Momonga with its complete tail and feet">

</details>

## Features

- Animated, transparent pets that float above regular windows.
- Character selection, dragging, optional wandering, and saved preferences.
- Adjustable size from 40% to 120%, with a default of 65%.
- Quota details, reset times, manual refresh, and automatic quota refresh every two minutes.
- macOS menu-bar controls and Windows system-tray controls, even when the pet is hidden.
- Signed app updates and optional automatic installation on macOS and Windows x64.
- Existing Claude Code and Codex logins; no separate account or server.
- Account-bound last-good snapshots, data-source/freshness labels, and per-account HTTP 429 cooldowns.
- Model-specific quota windows, ordered menu-bar/tray metrics, countdowns, and conservative pace estimates.
- Optional threshold/pace notifications, launch at login, and a recorded global panel shortcut.
- Multiple CLI homes and opt-in saved-account discovery, without switching or refreshing CLI accounts.
- Opt-in local token history and custom-price estimates, separate from subscription quotas and credits.

English is the default language. Select **English / 한국어** in the usage panel
or control menu; your choice is saved for the next launch. Windows GUI behavior is
still experimental; see [known limitations](#privacy-and-known-limitations).

## Installation

Download macOS and Windows packages from the same [v1.3.0 release](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.3.0).
Both platforms use the shared version `1.3.0`; the release's single `SHA256SUMS` covers all four packages below.

| Platform | Package | Installation |
|---|---|---|
| macOS 14+, Apple Silicon | `ChiikawaPet-1.3.0-mac-arm64.dmg` | Open the DMG and drag the app onto the Applications shortcut on the right. |
| macOS 14+, Intel | `ChiikawaPet-1.3.0-mac-x86_64.dmg` | Open the DMG and drag the app onto the Applications shortcut on the right. |
| Windows 10/11, x64 | `ChiikawaPet-1.3.0-win-x64-setup.exe` | Follow the illustrated wizard; launch on Finish or from the Start menu. |
| Windows 10/11, x64 | `ChiikawaPet-1.3.0-win-x64.zip` | Extract **all** files and run `ChiikawaPet.exe`. |

The Windows packages include .NET. The installer uses the current user's
`%LOCALAPPDATA%\Programs\ChiikawaPet` directory and adds an uninstall entry.
The portable EXE needs the other extracted files beside it.

Current packages are not signed with an Apple Developer ID or a Windows
code-signing certificate. If the OS blocks a download, review the source and
release checksums before using the OS's option to open or run it.

## Connecting accounts

1. Sign in to Claude Code with `/login`, or sign in to Codex with `codex login`.
2. Launch the pet, click it to open the usage panel, and select **새로고침** (Refresh).

API-key billing does not provide subscription quota percentages.

| Platform | Claude credentials | Codex credentials |
|---|---|---|
| macOS | `~/.claude/.credentials.json`, or the `Claude Code-credentials` keychain entry | `~/.codex/auth.json`, or the `Codex Auth` keychain entry for the configured home |
| Windows | `%USERPROFILE%\.claude\.credentials.json` | `%USERPROFILE%\.codex\auth.json`, or Codex's matching Credential Manager entry |

On macOS, Claude keychain reads use `/usr/bin/security` before native fallback and
reread the active account on every refresh. Locked keychains or items that do not
trust `security` may still prompt; stalled reads are stopped after five seconds.
Native fallback and Codex only allow authorization dialogs during manual Refresh.
Windows supports opt-in reads of Codex's classic keyring-rs Credential Manager format;
newer secret-store namespaces are not supported. WSL credentials are not discovered
automatically: add a Windows-accessible WSL home explicitly. See the [Windows guide](windows/README.md).

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` override default paths when inherited by the app.
You can also add CLI home directories in the panel, including when launching from Finder.
Expired credentials must be refreshed through the original CLI. The pet does not
renew tokens or modify credential files or keychain entries.

## Usage

| Action | Result |
|---|---|
| Click the pet | Toggle the usage panel |
| Drag the pet | Move it and save its position |
| Right-click the pet | Open the control menu |
| Click the macOS menu-bar item | Open the control menu |
| Left-click / right-click the Windows tray icon | Toggle the panel / open the control menu |
| Use the panel | Select a character, change size, toggle wandering or visibility, refresh, or quit |

The macOS app has no Dock icon. The Windows app has no taskbar button; check the
notification area's `^` overflow if its tray icon is hidden. Hiding the pet keeps
its menu-bar or tray controls available and stops its animation. Wandering pauses
near the pointer and while the usage panel is open.

### App updates

Open the macOS menu-bar menu or Windows tray menu and choose **Check for Updates…**.
Accept the install prompt to download the latest stable release, replace the app,
and restart it. Preferences and CLI sign-in files are preserved. Windows supports
both installed and portable x64 packages; portable updates leave unrelated files alone.

**Automatic Updates (every 6 hours)** is **off by default**. Enable it to check
at startup and every six hours, then install and restart automatically. The option
is saved. Turning it off before installation cancels automatic application.
Preview mode never checks or downloads app updates.

**Install 1.3.0 manually once if you are on 1.1.6 or earlier**; those versions
do not have an updater. On Mac, install into `/Applications`, not the mounted DMG.
Updates are authenticated with a pinned release key and SHA-256 before use.
This app-specific signature is not Apple notarization or Windows code signing;
OS security warnings can still appear. Updates replace the full package, not a delta.

### Quotas and expressions

Remaining quota is `max(0, 100 − utilization)`: exhausted or finite over-limit
usage stays at 0% with the crying expression. Negative and nonfinite usage remains
invalid. By default, the expression uses the lowest quota among current, verified
readings, rather than a sum or average. The panel identifies the limiting account
and window. Displayed integers round down; thresholds use the original decimals.

| Remaining quota | Expression |
|---|---|
| 95–100% | Delighted |
| 60% to below 95% | Happy |
| 30% to below 60% | Uneasy |
| Above 10% to below 30% | Sad |
| 0–10%, including exactly 10% | Crying |
| No valid reading | Unknown; never treated as 0% |

Only reported quota windows are shown. Stale, expired, unknown, or account-mismatched
measurements do not drive the expression or current menu-bar/tray values. Last-good
values remain clearly labeled in the panel. Character selection cards always use
their cheerful preview pose, independently of current usage.

### Monitoring preferences

The panel's monitoring/settings controls let you:

- Select all accounts or one account/window for the pet; change the four expression
  boundaries or opt into pace-based expressions.
- Pin individual quota windows to the menu bar/tray, reorder or remove them, and
  choose compact or bar rendering. Missing metrics show `—`, never an invented 0%.
- Show reset countdowns and pace estimates. Pace requires a known period and reset,
  a fresh measurement, and enough elapsed time; otherwise no estimate is shown.
  It extrapolates the current average rate, not the provider's future allowance.
- Enable quota/pace notifications, **off by default**. A first observation or a new
  reset establishes a baseline rather than notifying. Repeated refreshes do not
  repeat the same crossing; recovery can rearm it. Stale/cache-only data does not notify.
- Enable launch at login or record a global shortcut to toggle the panel. Registration
  failures are reported rather than silently treated as enabled.
- Add/remove explicit CLI homes or opt into saved-account discovery, **off by default**.
  Discovery reads supported local account stores; it does not log in, rotate tokens,
  modify credentials, or switch the CLI's active account.
- Copy sanitized diagnostics when reporting an issue. Never attach authentication files.

Measurement time and refresh-attempt time are separate. HTTP 429 respects the
provider's `Retry-After`; manual refresh cannot bypass an active cooldown. Persisted
last-good values remain account-bound and stale until verified again. Changing
accounts, crossing a reset, or invalidating credentials prevents reuse as current data.

### Local history, credits, and estimated cost

Local history is **off by default**. When enabled it reads the selected CLI home's
Claude project logs or Codex session/archive logs locally. Choose today, yesterday,
or the last 30 local-calendar days. A home can contain several accounts' sessions:
these totals are **home-scoped, not verified per-account billing**. Files are streamed
with safety limits; corrupt, unsupported, or truncated input produces an incomplete
data warning. Prompt and response text is not exported.

Provider-reported credits/spend are shown separately from quota percentages.
Token history does not reconstruct remaining subscription quota or actual invoices.
There are **no bundled prices**. Without an exact custom model price, tokens remain
unpriced—not a fabricated $0 charge. Estimates are in USD and exclude taxes,
discounts, contract terms, and provider-side adjustments.

Choose a custom pricing JSON file in the panel. The following rates are illustrative;
replace the exact model ID and every rate with your own pricing:

```json
{
  "version": 1,
  "models": {
    "replace-with-exact-log-model-id": {
      "inputPerMillion": 3,
      "outputPerMillion": 15,
      "cachedInputPerMillion": 0.3,
      "cacheWritePerMillion": 3.75,
      "cacheWriteOneHourPerMillion": 6
    }
  }
}
```

Rates are finite, nonnegative USD per million tokens. The first four rates are
required; the one-hour cache-write rate is optional but needed to price those events.
Unknown models, unsupported special service tiers, and missing rate categories
remain unpriced and are reported as such. History and pricing files are never uploaded.

## Development

Clone the repository and run commands from its root:

```sh
git clone https://github.com/meengi07/chiikawa-agent-pet.git
cd chiikawa-agent-pet
```

| Platform | Stack | Source-build requirements |
|---|---|---|
| macOS | Swift, AppKit, SwiftUI | macOS 14+, Swift 6+, Xcode or Command Line Tools |
| Windows | C#, .NET 10, WPF; Windows Forms tray icon | .NET 10 SDK and MSVC C++ build tools/Windows SDK for the native updater; NSIS for the installer |

### macOS

Install Command Line Tools with `xcode-select --install` if needed, then:

```sh
./Launch.command
./scripts/test.sh
```

`Launch.command` builds the app, quits the running copy, installs or updates
`/Applications/ChiikawaPet.app`, and launches that installed copy.
`test.sh` also supports Command Line Tools without full Xcode.

### Windows

```powershell
.\scripts\build-windows.ps1
```

This runs the logic checks and creates a self-contained app and portable ZIP.
Use `-Runtime win-arm64` for an ARM64 portable build. To create an x64 installer,
install [NSIS](https://nsis.sourceforge.io/Download) and run:

```powershell
.\scripts\package-windows.ps1
```

The Windows target can also be compiled from macOS or Linux:

```sh
dotnet run --project windows/Checks/Checks.csproj -c Release
dotnet publish windows/ChiikawaPet.csproj -c Release -r win-x64 --self-contained true -o build/windows/win-x64
```

Raw cross-compilation does not include the native-AOT updater or installer artwork.
Use the Windows scripts and the matching MSVC toolchain for complete release packages.
In-app updates support the released Windows x64 packages only.

### Project structure

```text
mac/       Swift sources, tests, and macOS app metadata
windows/     C# sources, logic checks, and installer definition
assets/      Shared sprite sheets and provider logos
scripts/     Build, test, packaging, and release checks
docs/        Release guide and release notes
VERSION      Shared MAJOR.MINOR.PATCH version for both platforms
```

Platform code stays separate. Both applications embed the same PNG files from
`assets/`. Sprite sheets contain eight columns and six expression rows, with
64×80-pixel frames.

### Previews

Quit the running pet first. Previews do not request real account usage.

```sh
open -n /Applications/ChiikawaPet.app --args --preview 10 --show-usage
```

```powershell
.\build\windows\win-x64\ChiikawaPet.exe --preview 10 --show-usage
```

## Releases and versioning

[VERSION](VERSION) is the sole version source for both applications and their package filenames. See the [release guide](docs/RELEASING.md) and [changelog](CHANGELOG.md).
The shared [.github/workflows/release.yml](.github/workflows/release.yml) workflow
builds both platforms for a `vMAJOR.MINOR.PATCH` tag. Package checks, signed update
metadata, and native update/rollback checks on both platforms must succeed before
it creates one **draft** release: four packages, `SHA256SUMS`, `updates.json`, and
`updates.sig`. Inspect the artifacts before deliberately publishing the draft.

## Privacy and known limitations

- Existing tokens are sent only to the corresponding provider's HTTPS usage/profile endpoints. There is no separate backend, browser-cookie collection, token logging, persistent token storage, or telemetry. Account labels, quota snapshots, and preferences are stored locally; opt-in history scans remain local. See the [macOS cache behavior and limits](mac/README.md#claude-swap-usage-cache-macos).
- Usage endpoints are observed interfaces, not guaranteed stable public APIs. Provider changes can break the integration.
- Windows GUI, installer execution, and mixed-DPI behavior require Windows validation. Cross-compilation and logic checks do not establish visual correctness.
- With Hidden Bar 1.11.1 on macOS 27, launch the app from `/Applications`. Apps launched from `build/`, Downloads, or `~/Applications` can be hidden even when placed to the right of Hidden Bar's arrow. The source launcher installs to the required location.
- Signing and notarization are not configured. Installer builds and source-code licensing do not grant rights to third-party artwork.

## Contributing

Bug reports and pull requests are welcome. Include your OS, architecture, steps
to reproduce, and relevant errors. Do not include tokens or credential files.
Run the checks for the platform you change and keep shared artwork in `assets/`.
When changing documentation, update both English and Korean versions.

## License and credits

Source code, scripts, and documentation are licensed under the [MIT License](LICENSE).
Character artwork and provider logos are **excluded**; see the [artwork notice](assets/NOTICE.md).
Bundled .NET components keep their own license notices under `licenses/` in Windows packages.
The sprites were derived from supplied pixel-art references. This project is
unofficial and is not affiliated with Chiikawa.
