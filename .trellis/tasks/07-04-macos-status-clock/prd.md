# macOS status bar clock with calendar and timezone appearance

## Goal

Create a native macOS 26 status bar clock app that can display the current time, upcoming iCloud calendars, selectable time zones, and appearance preferences including automatic light/dark switching based on a selected time zone.

## Requirements

- Provide a native macOS status bar app with no main Dock window by default.
- Show a live status bar clock using the system time zone plus any user-selected custom time zones.
- Show a popover with an overview page for world clocks/events and a settings page for time zones, appearance, and calendars.
- Integrate with macOS Calendar/iCloud through EventKit permissions and show upcoming events from user-selected calendars.
- Allow selecting all calendars or a subset of calendars for display.
- Allow choosing multiple display time zones, including the system time zone and custom time zones.
- Allow appearance mode: system, light, dark, or automatic by a selected time zone.
- Persist user choices locally.
- Provide a buildable project using the installed macOS 26 / Xcode 26 toolchain.

## Acceptance Criteria

- [ ] `swift build` succeeds on macOS with Xcode 26 toolchain.
- [ ] App launches as a native status bar application with an updating clock.
- [ ] Popover shows date/time, calendar authorization state, upcoming events, time zone picker, and appearance picker.
- [ ] EventKit calendars/events are requested through the system permission flow and filtered by selected calendar identifiers.
- [ ] Time zone and appearance choices persist across app restarts.
- [ ] Automatic appearance by time zone switches light/dark based on local daylight hours in the selected appearance time zone.

## Constraints

- Keep implementation dependency-free; use SwiftUI, AppKit, EventKit, and Foundation only.
- Prefer simple, testable services over complex architecture.
- Do not require destructive system changes or external accounts beyond the user's existing Calendar/iCloud setup.
