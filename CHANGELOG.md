# Changelog

mac and Windows are versioned independently through [mac/VERSION](mac/VERSION)
and [windows/VERSION](windows/VERSION).

## mac 1.1.0 — 2026-10-15

- Add Momonga with six expressions, blink animation, saved selection, and English/Korean names.
- Add English (default) and Korean UI modes with saved language selection.
- Fix macOS 27 / Hidden Bar 1.11.1 menu-bar hiding by installing and launching source builds from `/Applications` instead of the repository's `build/` directory; preserve the existing app preferences.

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
