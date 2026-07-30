# Consolidate date and time settings

## Goal

Make date, calendar, clock, and time-zone settings predictable to find by replacing the fragmented sidebar destinations with one "Date & Time" destination and a focused "Language" destination.

## Background

The settings sidebar currently spreads related controls across Date & Events, Menu Bar, Calendars, and Language & Region. Display time zones and the macOS system time zone also use similar language despite having different scopes. The user approved consolidating these controls using方案 A.

## Requirements

- Replace the Date & Events, Menu Bar, and Calendars sidebar panes with one Date & Time pane.
- Present the Date & Time pane as one scrollable surface with visible, continuous groups:
  - Menu Bar & Display: menu-bar date/time format, clock carousel, and overview display time zone.
  - Calendar & Events: calendar authorization/source selection and week start.
  - macOS System Time Zone: the existing system time-zone search/apply flow with explicit system-wide scope.
- Rename Language & Region to Language and keep only MenuCue language plus the link to macOS Language & Region settings.
- Keep appearance automation's reference time zone in Appearance because it controls appearance behavior.
- Preserve all existing settings values, persistence keys, iCloud fields, authorization behavior, and helper behavior.
- Route Overview's calendar status action to Date & Time.
- Update English and Simplified Chinese localization for all new or changed user-visible strings.

## Acceptance Criteria

- [x] The sidebar contains one Date & Time destination and no separate Date & Events, Menu Bar, or Calendars destinations.
- [x] Date & Time visibly separates app display clocks, calendar behavior, and the system-wide macOS time zone.
- [x] Language contains no embedded system time-zone editor and remains the destination for app language and macOS language settings.
- [x] Existing menu-bar format, clocks, overview time zone, week start, selected calendars, and appearance settings retain their values after the UI change.
- [x] Overview's calendar status link opens Date & Time and scrolls to Calendar & Events.
- [x] English and Simplified Chinese localization coverage passes.
- [x] Relevant unit tests and the full Swift test suite pass.

## Out of Scope

- Changing the settings storage schema or iCloud synchronization contract.
- Redesigning Appearance, iCloud, or unrelated settings panes.
- Fixing the separate AirPlay multi-display cleaning overlay issue.
