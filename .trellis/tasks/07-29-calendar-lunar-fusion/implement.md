# Implementation plan: calendar and lunar calendar fusion

## Delivery order

1. Complete `07-30-lunar-month-calendar` first. It establishes `CivilDateKey`, month projections, time-zone semantics, event overlap rules, and refresh lifecycle used by both later children.
2. Complete `07-30-statutory-holiday-data` after the shared date contract is stable. The publishing pipeline may be developed in parallel, but client integration waits for the month projection.
3. Complete `07-30-eventkit-reminders` after the shared date contract and month/agenda projection boundaries are stable.
4. Return to this parent for cross-child integration, migration, visual/accessibility review, and full regression verification.

## Parent integration checklist

- [ ] Freeze shared civil-date and day-presentation contracts before child implementation diverges.
- [ ] Verify all children use one overview-time-zone owner, fixed `Asia/Shanghai` solar-term semantics, one all-day event capture/regroup policy, and two-day EventKit query padding.
- [ ] Verify lunar text, statutory markers, event dots, and reminder indicators fit one stable month-cell geometry.
- [ ] Verify selected-date detail and today-anchored agenda keep distinct responsibilities.
- [ ] Verify scalar preferences and per-date overrides round-trip through the existing portable settings service without syncing EventKit identifiers.
- [ ] Verify update/cache failures never block Gregorian month rendering or EventKit features.
- [ ] Verify calendar and reminder permission denial/recovery independently.
- [ ] Verify all children add English and Simplified Chinese strings through `L10n` and preserve localization parity.
- [ ] Perform the PRD acceptance pass and record evidence before activating or archiving the parent.

## TDD and validation order

Each child starts with focused failing tests, reaches green with the smallest implementation, then refactors only after focused tests pass. The parent integration gate runs:

```bash
swift test
./scripts/verify-localizations.swift \
  Sources/MenuCue/Resources/en.lproj/Localizable.strings \
  Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings
swift build
./scripts/build-app.sh
codesign --verify --deep --strict .build/app/MenuCue.app
```

Manual app-bundle verification must cover:

- CN and non-CN first-run defaults, then persisted user overrides after a simulated region change
- system-default versus overview time-zone offset matrix through UTC-12/UTC+14, including padded all-day month boundaries
- month navigation at 1901/2100 boundaries, leap month, Lunar New Year, and fixed-China-date solar terms under multiple overview time zones
- EventKit external changes while the popover remains open
- all-day, cross-midnight, and multi-day event dots plus selected-date rows
- valid, stale, malformed, regressive, bad-signature, and canonical-byte/signature-envelope statutory fixtures
- offline launch with bundled/cached fallback
- KVS two-replica out-of-order normal merge, specialized pre-LWW import, first/account merge source choice, `Use iCloud`, `Use This Mac`, union writeback, permanent tombstone, reset generation, long-offline resurrection attempt, payload limit, and iCloud failure
- reminder denial/recovery, stale list/item identifiers, read-only lists, recurrence/alarm patching, provider rejection/post-save adjustment, completion undo, due-instant/midnight scheduling through sleep/clock changes, overdue/unscheduled groups, bounded completion-date pages across empty windows, explicit unknown-date full supplement, and deduplication
- packaged English/Simplified Chinese `NSRemindersFullAccessUsageDescription` and legacy reminder usage-key inspection
- VoiceOver reading order and largest supported accessibility text size without overlap

## Rollback points

- Do not remove old settings keys until migration tests pass against representative prior payloads.
- Keep each new presentation layer independently disableable through its user setting.
- Do not activate a downloaded statutory manifest until all validation succeeds and atomic persistence completes.
- Do not publish reminder write success until EventKit save and observed-result verification succeed.
- If integration exposes a shared contract defect, return the owning child to planning rather than patching a second date model into another child.

## Planning gate

Do not run `task.py start` for any child until its PRD, design, and implementation plan have passed convergence review and the user approves the final task map.
