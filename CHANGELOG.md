# Changelog

macOS and Windows share the root [VERSION](VERSION) and one `vMAJOR.MINOR.PATCH`
GitHub Release. Published platform-specific history below remains unchanged.

## 1.3.0 — 2026-10-22

- Restore Momonga's short, separate eyebrow strokes across all 12 open/blinking source poses (48 runtime frames) on macOS and Windows. Replace undersized dots and missing blink-pose brows so they remain readable after native sprite downscaling; preserve every other feature, silhouette, and alpha channel.
- Add account-bound quota snapshots and source/measurement-age/refresh status on both platforms. Honor account-specific HTTP 429 cooldowns and `Retry-After`, including manual refresh; prevent old-account and expired-reset values from driving current indicators.
- Parse Claude model limits and Codex additional rate-limit windows. Show account, plan, authentication source, extra credits, spend, and reset-credit counts without converting them into subscription percentages.
- Add configurable expression targets and boundaries, identify the limiting window, and keep character-selection previews cheerful. Offer ordered per-window menu-bar/tray pins, compact/bar rendering, reset countdowns, and opt-in pace estimates.
- Add opt-in deduplicated quota/pace notifications, native login startup and a recorded global panel shortcut. Shortcuts toggle the panel while notification clicks only open it; previews never restore native registrations. Preserve existing pet, language and update preferences. Keep notification authorization compatible with older macOS SDKs without disabling concurrency checks.
- Add explicit multiple CLI homes, opt-in supported saved-account discovery, Codex Windows Credential Manager reads, explicit Windows-accessible WSL paths, and sanitized diagnostics. Never refresh tokens, switch accounts or write other tools' credentials.
- Add opt-in streamed Claude/Codex local token history with replay deduplication, safety/incompleteness warnings and local-day periods. Keep totals home-scoped and separate from quota/credits; custom exact-model USD rates are required for cost estimates, with unknown models/tiers left unpriced.
- Remove only the installed copy's own Windows login-startup entry during uninstall; preserve another portable copy's entry and existing preferences/CLI credentials.
- Wait up to five seconds for Windows sharing/lock violations during installed directory replacement and rollback. Preserve atomic renames, fail other filesystem errors immediately, and keep real lock-release/destination-preservation regressions.

## 1.2.1 — 2026-10-21

- Refine Usagi across all 48 shared sprite frames: thin, tapered eyebrows that remain connected at menu-bar size, round highlighted eyes, a compact character-style mouth, short blush hatching, and pooled tears. Preserve the silhouette, six moods, and blink animation on macOS and Windows.
- Reuse the macOS claude-swap schema-2 usage cache for verified default-keychain accounts to reduce Claude HTTP 429 errors ([#7](https://github.com/meengi07/chiikawa-agent-pet/issues/7), thanks to [@GooTec's investigation in #3](https://github.com/meengi07/chiikawa-agent-pet/pull/3)). Verify account ownership through the same token's OAuth profile, match email and organization, and reject ambiguous rows, future timestamps, invalid data, and pre-reset measurements. Reuse readings under 15 minutes old before a usage request and up to one hour old only after HTTP 429, preserving their measurement time.
- Retain the five-second keychain timeout, plaintext/hex decoding, native fallback, custom/file credential isolation, and unchanged Codex/Windows behavior. Keep cache access read-only; profile verification is memory-only and repeated when the token changes.

## 1.2.0 — 2026-10-16

- Add manual stable-release checks and verified in-app installation on macOS (Apple Silicon/Intel) and Windows x64 (installed/portable).
- Add a saved automatic-update option, off by default, checking on startup and every six hours with automatic installation and restart. Disabling it before installation cancels automatic application; previews never perform updater I/O.
- Authenticate raw release manifests with a pinned ECDSA P-256 key and verify package size/SHA-256 before use. Generate signed metadata in CI without distributing the private key.
- Apply updates through native helpers, retain a backup until startup acknowledgement, and restore/relaunch the previous app on startup failure. Preserve pet preferences, CLI sign-ins, Windows registry version, and unrelated portable-directory files.
- Gate release creation on native signed-package replacement/restart, rollback, and invalid-input checks for both Mac architectures and Windows installed/portable modes.
- Install 1.2.0 manually once from 1.1.6 or earlier. App-specific update signatures do not provide Apple notarization or Windows public code signing.

## 1.1.6 — 2026-10-16

- Match the Windows installer to the macOS DMG with a cream/pastel palette, all four pixel characters, branded setup/uninstall icons, and an embedded multi-size app icon.
- Add concise English/Korean welcome/completion guidance, optional launch on Finish, a styled uninstall completion page, and a branded Installed Apps entry.
- Exercise real native install/uninstall wizards, finish launch, installed EXE input, preference/credential preservation, running-pet guards, and silent installation compatibility. Upload rendered wizard screenshots for visual release review.
- Preserve fixed per-user installation and existing preferences. macOS shares version 1.1.6 without runtime changes; public code signing remains unavailable.
- Create portable ZIP entries with standard forward slashes even under Windows PowerShell 5.1, preserving runtime-license paths across extraction tools. The v1.1.5 release was blocked by portable ZIP validation; its tag remains unchanged.

## 1.1.4 — 2026-10-16

- Redesign macOS DMGs with a Retina cream background, all four pixel characters, a directional arrow, and fixed app/Applications icon placement for drag installation.
- Generate a matching transparent macOS app/volume icon from existing sprites, including legible small sizes.
- Keep bilingual documentation inside the signed app instead of loose installer files; build Finder metadata headlessly with pinned DMG tools.
- Verify each finished DMG's bundled code signature and global Applications shortcut before accepting the package. Windows shares version 1.1.4 without runtime changes.

## 1.1.3 — 2026-10-16

- Read the current Claude macOS keychain item through the trusted `security` tool on each refresh before native fallback, preserving account-switcher compatibility without token caching or keychain writes ([#1](https://github.com/meengi07/chiikawa-agent-pet/issues/1)). Stop stalled tool reads after five seconds; locked or untrusted items can still request authorization.
- Keep exhausted and finite over-limit Claude/Codex readings at 0% with the crying expression on both platforms instead of discarding the provider response; still reject negative and nonfinite usage ([#6](https://github.com/meengi07/chiikawa-agent-pet/issues/6)).
- Restore Windows drag handling before the button consumes mouse-move events, preserving click-versus-drag behavior and saved positions ([#4](https://github.com/meengi07/chiikawa-agent-pet/issues/4)).
- Exit Windows fully when the main pet window closes, releasing the single-instance mutex so the pet can be started again; explicit hiding still retains the tray ([#5](https://github.com/meengi07/chiikawa-agent-pet/issues/5)).
- Add native Windows UI smoke coverage for dragging, persistence, capture loss, keyboard activation, hiding, close cleanup, and relaunch alongside the installer checks.
- Fix Windows usage-window close reentrancy: detach the active panel on `Closing` before `Deactivated` can close it again, preventing `InvalidOperationException` from terminating the pet.
- Verify ordinary self-contained portable and installed Windows EXEs with animation and refresh enabled; detect modal error dialogs and check native usage-window close rather than relying on preview-only process liveness.

## 1.1.2 — 2026-10-15

- Unify macOS and Windows on version 1.1.2, one `v1.1.2` tag, and one release workflow.
- Publish both macOS DMGs, the Windows installer, and the Windows portable ZIP together with one combined `SHA256SUMS`.
- Include Momonga, six expressions, blink animation, saved character selection, and English/Korean UI from the preceding platform releases.
- Include the macOS packaged sprite/logo resource-loading fix and clean app-bundle updates that remove obsolete files while preserving preferences.
- Keep the `/Applications/ChiikawaPet.app` installation requirement for Hidden Bar 1.11.1 on macOS 27.
- Apple Developer ID signing/notarization and Windows code signing remain unavailable; Windows visual and mixed-DPI behavior still require manual verification.

## mac 1.1.1 — 2026-10-15

- Add Momonga with six expressions, blink animation, saved selection, and English/Korean names.
- Add English (default) and Korean UI modes with saved language selection.
- Fix macOS 27 / Hidden Bar 1.11.1 menu-bar hiding by installing and launching source builds from `/Applications` instead of the repository's `build/` directory; preserve the existing app preferences.
- Resolve packaged sprites and provider logos from the app's resource directory before SwiftPM's command-line bundle fallback, fixing CI-built app startup.
- Build fresh app bundles and remove obsolete installed files during source-launcher updates to preserve valid resource signatures.

## Windows 1.1.0 — 2026-10-15

- Add Momonga with six expressions, blink animation, saved selection, and English/Korean names.
- Add English (default) and Korean UI modes with saved language selection.

## mac 1.0.0 — 2026-10-14

- Animated Chiikawa, Hachiware, and Usagi pets with Swift/AppKit/SwiftUI.
- Claude and Codex quota details, expressions, reset times, and menu-bar controls.
- Saved character, size, position, visibility, and wandering preferences.
- Apple Silicon and Intel DMG packages with English/Korean documentation and an artwork notice.

## Windows 1.0.0 — 2026-10-14

- C#/.NET 10/WPF pets with notification-area controls and saved preferences.
- Concurrent Claude/Codex quota refresh using local CLI credential files.
- Current-user installer and portable ZIP, including .NET runtime licenses.
- Fix the NSIS payload wildcard to use the Windows path separator.
- Automated installation, preview-startup, and uninstall checks.

## Repository

- Independent platform release tags: `mac-v1.0.0` and `windows-v1.0.0`.
- Shared sprites and logos; MIT source-code license with separate artwork scope.
- English README and Korean documentation linked in both directions.

Packages are not signed with an Apple Developer ID or Windows code-signing certificate.
Mixed-DPI and visual behavior require manual Windows verification.
