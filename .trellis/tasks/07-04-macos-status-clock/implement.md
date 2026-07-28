# Implementation Plan

## Steps

1. Create a Swift Package executable for a macOS AppKit/SwiftUI status bar app.
2. Add app entry point, Info.plist, and status item/popover wiring.
3. Implement settings persistence for display time zone, appearance mode, appearance time zone, and selected calendars.
4. Implement EventKit calendar authorization, calendar loading, and upcoming event fetching.
5. Build SwiftUI popover views for clock, events, calendar selection, time zone selection, and appearance controls.
6. Apply appearance mode updates and automatic switching by selected time zone.
7. Run `swift build` and fix compile issues.

## Validation Commands

- `swift build`
- `swift test` if tests are added later

## Review Gates

- Keep all production code under `Sources/TouchMacer`.
- Avoid third-party dependencies.
- Do not add unrelated Trellis/spec changes.
