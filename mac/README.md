# Chiikawa Agent Pet for macOS

[English](README.md) | [한국어](README.ko.md)

An unofficial floating pixel-art pet for macOS 14 or later. The app uses Swift,
AppKit, and SwiftUI and runs from the menu bar without a Dock icon.

## Installation

Download `ChiikawaPet-1.3.0-mac-arm64.dmg` for Apple Silicon or
`ChiikawaPet-1.3.0-mac-x86_64.dmg` for Intel from the shared
[v1.3.0 release](https://github.com/meengi07/chiikawa-agent-pet/releases/tag/v1.3.0).
Its single `SHA256SUMS` covers both DMGs and both Windows packages.
Open the DMG and drag `ChiikawaPet.app` from the left onto the Applications
shortcut on the right, following the arrow. Launch `/Applications/ChiikawaPet.app`.
The Retina-ready installer has a cream background and all four pixel characters.
Quit a running pet before replacing the app manually.

With Hidden Bar 1.11.1 on macOS 27, use exactly `/Applications/ChiikawaPet.app`.
Its native visibility restriction can hide apps launched from other directories,
including `~/Applications`, even when their icons are on the visible side.

The current app is ad-hoc signed and has no Apple Developer ID notarization.
If macOS blocks it, review the source and release checksum, then use System
Settings → Privacy & Security → Open Anyway if you want to run that download.

## Language

English is the default. Choose English or 한국어 in the usage panel or control menu.
The choice is applied immediately and saved for the next launch.

## Controls

- Click the pet to toggle its usage panel; drag it to move it.
- Right-click the pet or click its menu-bar item to open the control menu.
- Use the panel to select a character, change size (40–120%, default 65%),
  toggle wandering or visibility, refresh usage, or quit.
- Menu-bar controls remain available when the desktop pet is hidden.

The menu bar shows the pet and provider logos. In the panel, choose individual
account/window metrics, reorder them, and select compact or bar rendering. With no
custom pins, the default selection is used. Unknown or stale metrics show `—`.

## App updates

Choose **Check for Updates…** from the menu bar or pet's right-click menu.
Accept the install prompt to download, verify, replace, and restart the app.
Preferences and CLI sign-ins stay intact; a startup failure restores the previous app.
The destination must be writable and outside the DMG; use `/Applications`.

**Automatic Updates (every 6 hours)** is saved and **off by default**. When enabled,
checks run at startup and every six hours and install newer stable releases automatically.
Disable it before installation to cancel automatic application. Previews never check
or download updates. Packages use a pinned release key and SHA-256; this does not
provide Apple Developer ID signing or notarization.

Versions 1.1.6 and earlier have no updater: install 1.3.0 manually once.

## Accounts

Sign in to Claude Code with `/login` or Codex with `codex login`, then click
**새로고침** (Refresh). The app reads the default CLI credential files or matching
macOS keychain entries. Claude's default keychain item is reread through
`/usr/bin/security` before native fallback on every refresh, including after account
switches. Locked or untrusted items may request authorization; stalled tool reads
are stopped after five seconds. Native fallback and Codex only allow authorization
dialogs during manual Refresh.

Custom `CLAUDE_CONFIG_DIR` and `CODEX_HOME` paths are supported. Finder does not
inherit shell environment variables, so run the installed executable directly
from the configured terminal:

```sh
/Applications/ChiikawaPet.app/Contents/MacOS/ChiikawaPet
```

The pet does not renew tokens or modify CLI credential files or keychain items.
Use the original CLI to reauthenticate. API-key billing has no subscription quota percentage.

Use the panel's monitoring preferences to add an explicit Claude or Codex home.
This also works when Finder does not inherit `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
Optional saved-account discovery is off by default and reads supported cswap/xswap
stores without activating accounts or modifying them. Account labels, plan,
authentication source, measurement origin/age, and retry timing are shown separately.

Last-good snapshots are saved locally without credentials and restored as stale.
Current identity and reset boundaries must still be verified before a value can
drive the pet or menu bar. HTTP 429 cooldowns also apply to manual refresh.

## Monitoring and system preferences

Choose the account/window that drives the pet, adjust expression boundaries, pin
menu-bar metrics, or enable reset countdowns and conservative usage-pace estimates.
The panel names the limiting window; character-picker previews stay cheerful.
Quota and pace notifications are opt-in and deduplicated. Login startup uses macOS
Login Items; the panel reports registration/permission failures. Record a global
panel shortcut or remove it to release the shortcut.

Local history and saved-account discovery are **off by default**. History reads
only the chosen CLI home's logs; it is not verified per-account billing.
There are no bundled token prices. See the root guide for [history attribution,
unpriced tokens, and the custom pricing format](../README.md#local-history-credits-and-estimated-cost).
Copy sanitized diagnostics from the panel for a bug report; do not attach CLI
authentication files. These options preserve the existing pet, language, and update settings.

### claude-swap usage cache (macOS)

For the default Claude keychain login, the pet can read cswap's schema-2
`~/.claude-swap-backup/cache/usage.json` to avoid competing usage requests.
When a usable cache exists, it verifies the current token's account with Claude's
`/api/oauth/profile` endpoint. That verification is reused in memory for the same
token; a changed token is verified again. Missing or unresolvable identity falls
back to the normal usage request, never a guessed account.

Cache rows must match both email and organization UUID; duplicate matches are
ignored. Measurements under 15 minutes old avoid the usage request. Only after
HTTP 429 may the pet use a measurement up to one hour old. Future timestamps,
expired quota-window resets, unsupported schemas, and invalid cache data are
not reused. The panel retains the original measurement time, not the refresh time.

Custom Claude directories, file-based credentials, Codex, and Windows do not use
this cache integration. The pet never writes the cswap cache or refreshes tokens.
Legacy slot-only cswap cache rows without verifiable account identity are not reused.

## Building from source

Install Swift 6+ through Xcode or Command Line Tools, then run from the repository root.
DMG packaging also needs Python 3.10+; pinned tools are installed into `build/dmg-tools`,
not the system Python. Finder does not need to run during packaging.

```sh
./Launch.command
./scripts/test.sh
./scripts/package-mac.sh arm64
```

`Launch.command` builds, quits the running pet, installs or updates the app in
`/Applications`, and launches that copy. The build and packaging scripts alone
do not install it.

The root [VERSION](../VERSION) sets the version for both macOS and Windows.
Use `x86_64` to build an Intel DMG. Packages go to `build/release/mac/1.3.0/`.
Quit the running app before trying a preview, which performs no account requests:

```sh
open -n /Applications/ChiikawaPet.app --args --preview 10 --show-usage
```

Source code is MIT licensed; the app's `Contents/Resources` includes both README
languages, `LICENSE`, and `ARTWORK-NOTICE.md` for character images and provider logos.
