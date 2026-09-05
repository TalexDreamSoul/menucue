<p align="center">
  <img src="https://ld.xh.do/ld-badge.svg" alt="认可 linux.do" width="480">
</p>

# MenuCue

MenuCue is a lightweight native macOS menu-bar dashboard built with AppKit, SwiftUI, EventKit, and Foundation.

## Features

- Configurable menu-bar date/time formatting with structured controls, advanced Unicode patterns, live preview, validation, and reset.
- Ordered system/custom world-clock carousel with drag reordering, custom labels, timed rotation, and mouse-wheel or trackpad switching directly over the status item. A gesture selection remains visible for one configured interval, then timed rotation resumes automatically; context-menu clock selection remains pinned until **Auto Rotate** is selected.
- Overview popover with world clocks, current system time zone, and upcoming events, plus a sidebar settings window for clock formatting, time zones, iCloud Sync, Calendar filters, appearance, app info, and update checks.
- EventKit Calendar integration for iCloud/local calendars configured in macOS Calendar.
- Calendar picker for all calendars or selected calendars.
- Appearance modes: system, light, dark, or automatic by a selected time zone, with an optional switch to apply the result to macOS system Light/Dark appearance.
- Native Launch at Login control through macOS Service Management.
- Packaged macOS app icon for Finder, the Dock, and system Login Items.
- Local settings persistence through `UserDefaults`, with opt-in iCloud key-value synchronization for portable preferences in entitlement-enabled builds.
- Configurable 4×2 Quick Actions grid with up to seven pinned actions and a fixed More entry.
- Fourteen built-in macOS actions plus Apple Shortcuts discovery, execution, availability feedback, and ordering in Settings.

## Install with Homebrew

```bash
brew install --cask talexdreamsoul/tap/menucue
```

MenuCue requires macOS 13 Ventura or newer. Release builds are signed with Developer ID and notarized by Apple.

## Build

```bash
swift build
```

## Build App Bundle

Calendar permissions, the packaged icon, and Launch at Login require the app bundle. Use:

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/app/MenuCue.app
```

By default, the script uses an available `Apple Development` identity so local macOS privacy grants remain valid across rebuilds. If none is available, it falls back to ad-hoc signing; explicitly use `CODESIGN_IDENTITY="-"` for the same local-only fallback. Public releases must use a `Developer ID Application` identity, a non-device-bound Developer ID provisioning profile, hardened runtime, and Apple notarization:

```bash
BUILD_CONFIG=release \
REQUIRE_STABLE_SIGNING=true \
CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
APPLE_TEAM_ID="YOURTEAMID" \
PROVISIONING_PROFILE="/path/to/MenuCue-DeveloperID.provisionprofile" \
scripts/build-app.sh

NOTARYTOOL_PROFILE="MenuCue-Notarization" \
EXPECTED_VERSION="0.9.6" \
EXPECTED_BUILD="40"
scripts/build-update.sh
```

`build-update.sh` submits the signed app to Apple, waits for acceptance, staples and validates the notarization ticket, requires a successful Gatekeeper assessment, and only then creates the Sparkle archive.

## Notes

- Calendar data continues to come from macOS Calendar/EventKit; MenuCue never stores iCloud credentials or duplicates calendar contents. Entitlement-enabled builds can separately sync portable display preferences through `NSUbiquitousKeyValueStore`; ad-hoc builds hide this capability and remain local-only.
- Automatic appearance uses light mode from 07:00 to 19:00 in the selected reference time zone, and dark mode otherwise.
- System-level appearance switching requires macOS Automation permission and is disabled until you enable it in Settings. When enabled, MenuCue periodically corrects macOS if another automatic schedule changes Light/Dark mode away from the selected setting.
