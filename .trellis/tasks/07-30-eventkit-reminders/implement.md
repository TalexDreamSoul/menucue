# Implementation plan: EventKit reminders integration

## Delivery order

1. `07-30-reminders-read-timeline` freezes authorization, DTOs, list normalization, date semantics, and agenda projections.
2. `07-30-reminders-core-crud` adds scalar-field writes, completion/undo, deletion, and observed-result handling.
3. `07-30-reminders-advanced-fields` adds recurrence/alarm editing and bounded all-history completion pagination.
4. This parent verifies shared contracts and packaging; it does not duplicate child implementation.

## RED: authorization, fetch, and projection

- [ ] Add fake-store tests for independent reminder permission states and recovery action.
- [ ] Add cancellable bounded incomplete fetch, selected-list/stale-id normalization, EventKit-change coalescing, due-instant/midnight scheduler, and completion-window plus explicit full-supplement tests.
- [ ] Add date-only/floating/timed/unscheduled/DST mapping plus timed-instant and next-civil-day overdue tests.
- [ ] Add unified agenda ordering and completed-indicator exclusion tests.

## GREEN: read path

- [ ] Add reminder store protocol, EventKit implementation, immutable projections, and AppModel lifecycle.
- [ ] Add independent list filtering and local persistence.
- [ ] Add month indicators, selected-date reminder rows, unified seven-day agenda, and overdue/unscheduled groups.
- [ ] Add completed visibility state without any iCloud identifier sync.

## RED: writes and editor

- [ ] Add draft validation and writable-destination tests.
- [ ] Add fresh-item dirty-field patch tests for create/edit/complete/reopen/delete/undo observed results and invalid identifiers.
- [ ] Add simple/advanced writable recurrence-initializer and relative/absolute/geofence alarm round-trip fixtures; assert `firstDayOfTheWeek` is display-only.
- [ ] Add untouched procedure-alarm, provider save rejection, and successful post-save adjustment tests.

## GREEN: writes and editor

- [ ] Implement fresh-item dirty-field patching, save/remove/re-fetch comparison, invalid-identifier cancellation, and typed rejection/adjustment results.
- [ ] Build the progressive reminder editor with standard controls, validation, capability feedback, and delete confirmation.
- [ ] Implement completion removal, short undo, and `Show Completed` recovery.
- [ ] Add denied/restricted/empty/loading/error states and System Settings recovery.

## REFACTOR

- [ ] Ensure EventKit objects remain inside the service boundary and view code consumes projections only.
- [ ] Ensure reminder content is never written to disk/logs and identifiers never enter iCloud settings.
- [ ] Audit packaged InfoPlist keys/localizations, cancellation, actor isolation, repeated EventKit notifications, and editor dismissal races.
- [ ] Audit keyboard navigation, focus order, VoiceOver, reduced motion, and largest accessibility text size.

## Validation

```bash
swift test --filter Reminder
swift test --filter Popover
swift test --filter Localization
./scripts/verify-localizations.swift \
  Sources/MenuCue/Resources/en.lproj/Localizable.strings \
  Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings
swift test
swift build
./scripts/build-app.sh
codesign --verify --deep --strict .build/app/MenuCue.app
```

Manual permission smoke tests use a disposable reminder list and cover denial recovery, read-only source, advanced recurrence/alarm save, geofence rejection, external Reminders.app change, completion undo, delete confirmation, and relaunch persistence of filters/UI state.
