# Design: macOS status bar clock

## App Shape

The app is a Swift Package executable that creates an AppKit `NSApplication` with an `NSStatusItem` and SwiftUI popover content. It targets macOS 26 but keeps APIs compatible with the installed SDK.

## Components

- `StatusClockApp`: application entry point and delegate wiring.
- `StatusBarController`: owns status item, popover, and timer updates.
- `AppModel`: observable state container for settings, calendar authorization, calendar list, and event list.
- `SettingsStore`: persists user-facing choices in `UserDefaults`.
- `CalendarService`: wraps EventKit authorization, calendar fetching, and upcoming event querying.
- `AppearanceService`: applies `NSApp.appearance` for system/light/dark/automatic-by-time-zone modes.
- SwiftUI views: popover layout, event list, calendar selection, time zone selection, and appearance controls.

## Data Flow

1. App starts and loads persisted settings.
2. Status bar controller starts a minute-level timer and renders the selected display time zone in the status item title.
3. Popover opening triggers calendar refresh and event loading.
4. Settings changes are persisted immediately and re-applied to clock title, events, and app appearance.
5. Automatic appearance uses the selected appearance time zone and switches to dark outside 07:00-19:00 local time.

## Calendar/iCloud

EventKit is the native macOS Calendar integration surface. iCloud calendars appear through the user's Calendar account configuration; the app does not store iCloud credentials.

## Tradeoffs

- Swift Package avoids brittle hand-written Xcode project files while remaining native and buildable with `swift build`.
- Daylight-hour appearance is intentionally deterministic and offline; it does not depend on location services.
- Calendar selection uses calendar identifiers persisted in `UserDefaults`; missing calendars are ignored gracefully.
