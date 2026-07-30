# Support more macOS versions

## Problem

MenuCue 0.6.5 declares macOS 14 Sonoma as its minimum even though most of the product can run on macOS 13 Ventura. Homebrew therefore refuses installation on Ventura, and the Cask metadata is also stale at 0.6.3 with an obsolete development-signing warning.

## Requirements

- Lower the supported deployment target from macOS 14.0 to macOS 13.0.
- Preserve core behavior on macOS 14 and newer.
- On macOS 13, provide compatibility behavior for EventKit authorization and SwiftUI APIs introduced in macOS 14 or macOS 13.3.
- Keep persisted settings formats, iCloud fields, Helper protocol, and release signing behavior unchanged.
- Do not claim macOS 12 support: it would require replacing macOS 13 foundations including `SMAppService`, `NavigationSplitView`, and SwiftUI `Layout`.
- Produce a notarized Developer ID release whose Info.plist and Mach-O load commands both declare macOS 13.0.
- Update the Homebrew Cask to the new release, require Ventura instead of Sonoma, and remove the obsolete development-signing caveat.
- Preserve unrelated working-tree changes from the status-clock and calendar/lunar tasks.

## Acceptance Criteria

- `Package.swift` declares `.macOS(.v13)` and the app bundle declares `LSMinimumSystemVersion=13.0`.
- A clean build with deployment target 13 succeeds without unavailable-API diagnostics.
- The full test suite passes under the macOS 13 deployment target.
- The release app main executable and Helper report Mach-O `minos 13.0`.
- The app extracted from the final release ZIP passes strict codesign, stapler, and Gatekeeper validation.
- GitHub publishes v0.6.6 (22), and the signed appcast points to it with minimum system version 13.0.
- The Homebrew Cask points to v0.6.6, uses the release SHA-256, and declares `depends_on macos: :ventura`.
