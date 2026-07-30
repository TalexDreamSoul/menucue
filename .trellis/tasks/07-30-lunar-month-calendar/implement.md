# Implementation plan: lunar month calendar and event semantics

## RED

- [x] Add failing tests for `CivilDateKey`, 42-cell month ranges, week settings, DST and UTC+14/UTC-12 boundaries.
- [x] Add failing event-overlap tests for system/overview offset extremes, two-day query padding, captured all-day keys, regroup policy, zero-duration, cross-midnight, and multi-day events.
- [x] Add failing lunar/festival golden tests including leap months and both New Year's Eve month lengths.
- [x] Add failing fixed-`Asia/Shanghai` solar-term resource validation, multi-overview-time-zone stability, and 1900/2101 fallback tests.
- [x] Add failing refresh-coalescing tests for EventKit/day/time-zone/locale/significant-time/wake notifications.
- [x] Add failing settings migration, regional default, persistence, and portable sync tests.

## GREEN

- [x] Add shared pure civil-date/month/event projection models.
- [x] Implement Foundation-backed lunar provider and independent 12-festival resolver.
- [x] Add sourced 1901-2100 solar-term resource and typed loader.
- [x] Extend `CalendarService` to bounded visible-range queries and overlap projection.
- [x] Add lifecycle observers and targeted cache invalidation in `AppModel`/controller ownership boundaries.
- [x] Extend month-cell and selected-date projections/views without changing the status item.
- [x] Add localized settings toggle, regional first default, persistence, and portable sync field.

## REFACTOR

- [x] Remove duplicate date grouping from SwiftUI views and ensure sibling tasks can import the shared contracts.
- [x] Reuse formatter/cache instances and verify view bodies do no file I/O or EventKit queries.
- [x] Audit fixed cell dimensions, truncation, VoiceOver ordering, and largest accessibility text size.

## Validation

```bash
swift test --filter Calendar
swift test --filter Lunar
swift test --filter SettingsStoreTimeZone
swift test --filter PreferenceSync
./scripts/verify-localizations.swift \
  Sources/MenuCue/Resources/en.lproj/Localizable.strings \
  Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings
swift test
swift build
```

Manual bundle checks cover month navigation, open-popover external EventKit change, region defaults, overview time-zone switching, and non-overlapping cell content.

## Completion evidence (2026-07-30)

- Calendar-focused tests: 24 passed, covering 42-cell layout, DST, UTC+14/UTC-12, lunar/festival golden dates, solar-term integrity, exact event overlap, recurring occurrence IDs, Agenda projection, and refresh coalescing.
- Full suite: 410 XCTest tests passed with 1 intentional skip; 5 Swift Testing tests passed.
- Localization verification: 824 English and Simplified Chinese keys matched.
- Build/package: `swift build` and `scripts/build-app.sh` passed; deep strict code-sign verification passed.
- Packaged solar-term table and metadata matched their source files byte-for-byte; schema, 1901-2100 coverage, 24 unique dates per year, and SHA-256 passed.
- Offscreen rendering verified nonblank month/date-detail output with lunar text and event dots; temporary rendering scaffolding was removed.
- Final independent review found no Blocker, Major, Minor, or unresolved question.
- Trellis remains `in_progress` only because the verified work is intentionally uncommitted; archive after an explicitly authorized commit.
