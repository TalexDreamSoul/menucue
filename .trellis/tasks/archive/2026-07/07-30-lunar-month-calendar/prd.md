# Lunar month calendar and event semantics

## Goal

Add trustworthy lunar context to MenuCue's existing 42-cell month calendar while establishing one civil-date and event-overlap model for later statutory and reminder integration.

## Background

- `StatusPopoverView.swift` already owns the month grid, selected date, week numbers, event dots, and seven-day agenda.
- `CalendarService.swift` currently queries a short upcoming range and `AppModel.swift` refreshes on explicit lifecycle actions, but the app does not cover all EventKit/time/locale notifications.
- Foundation Chinese calendar conversion is sufficient for lunar month/day, leap month, and localized sexagenary year. Solar terms require sourced data.

## Requirements

- Introduce pure `CivilDateKey`, month-range, event-overlap, lunar-date, and day-presentation models outside SwiftUI views.
- Use the overview time zone for Gregorian month construction, lunar conversion, timed-event grouping, and day rollover; keep solar-term labels fixed to `Asia/Shanghai` civil dates.
- Capture each all-day event's civil key immediately after fetch using EventKit's system-default-time-zone semantics. Preserve it by default and provide the portable overview-time-zone regrouping option.
- Pad EventKit month/agenda queries by two days on each boundary before local projection.
- Assign multi-day and cross-midnight events to every intersecting visible civil date.
- Add one stable month-cell secondary line with priority `festival > solar term > lunar date`; preserve Gregorian primary text, week behavior, and up to three event colors.
- Show full lunar date, leap-month state, sexagenary year, solar term/festival, and selected-date events in the date detail.
- Support the agreed 12 non-leap traditional festivals and dynamically derived Lunar New Year's Eve.
- Load a provenance-documented 1901-2100, 24-terms-per-year resource and degrade to lunar-only outside coverage.
- Refresh after EventKit changes, civil-day rollover, system/overview time-zone changes, locale changes, significant time changes, and wake.
- Add a portable lunar-display preference; default it on only for `CN`, `HK`, `MO`, `TW`, and `SG` when no value is stored.
- Keep the status item unchanged.

## Acceptance Criteria

- [x] Pure tests cover 42-cell month construction, configured first weekday/week number, leap years, DST, overview time zones, and stable `CivilDateKey` serialization.
- [x] All-day capture/regroup policy, two-day query padding, cross-midnight, and multi-day events produce identical month dots and selected-date membership across system/overview offset extremes.
- [x] Enabling lunar display adds exactly one non-overlapping secondary line and disabling it restores the existing geometry.
- [x] Foundation lunar output passes Spring Festival, leap-month, and time-zone-boundary golden cases.
- [x] All 12 festivals avoid leap-month duplication and New Year's Eve passes 29-day and 30-day final-month cases.
- [x] Solar-term resource integrity proves fixed `Asia/Shanghai` civil-date semantics, 1901-2100 coverage, and exactly 24 unique valid dates per year; overview time-zone changes do not move labels and out-of-range dates degrade safely.
- [x] EventKit/time/locale/wake notifications update an open popover through coalesced refreshes.
- [x] Lunar preference migration, first-region default, local persistence, and field-level iCloud round-trip are tested.
- [x] English/Simplified Chinese localization and VoiceOver cell/date-detail output remain complete.
- [x] Focused tests, `swift test`, localization verification, and `swift build` pass.

## Constraints

- No third-party runtime dependency for lunar conversion.
- Do not copy MacCalendar code or its unlicensed solar/holiday datasets.
- If LunarBar implementation or data is copied substantially, preserve MIT attribution; prefer independent implementation against Foundation and documented source data.
- Statutory schedules, reminders, and menu-bar lunar formatting belong to sibling/later tasks.
