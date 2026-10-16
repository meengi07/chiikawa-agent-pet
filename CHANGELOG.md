# Changelog

macOS and Windows share the root [VERSION](VERSION) and one `vMAJOR.MINOR.PATCH`
GitHub Release. Published platform-specific history below remains unchanged.

## Unreleased

- Read the current Claude macOS keychain item through the trusted `security` tool on each refresh before native fallback, preserving account-switcher compatibility without token caching or keychain writes ([#1](https://github.com/meengi07/chiikawa-agent-pet/issues/1)). Stop stalled tool reads after five seconds; locked or untrusted items can still request authorization.
- Keep exhausted and finite over-limit Claude/Codex readings at 0% with the crying expression on both platforms instead of discarding the provider response; still reject negative and nonfinite usage ([#6](https://github.com/meengi07/chiikawa-agent-pet/issues/6)).

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
