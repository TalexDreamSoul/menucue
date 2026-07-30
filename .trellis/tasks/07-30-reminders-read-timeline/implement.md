# Implementation plan: reminder authorization and read timeline

## RED

- [ ] Add authorization and packaged usage-description tests.
- [ ] Add phased fetch/cancellation/generation/list-id normalization tests.
- [ ] Add date-only/floating/timed/DST/overdue/unscheduled projection plus due-instant/midnight scheduler, cancellation, sleep, clock rollback, and time-zone-change tests.
- [ ] Add large-fixture render-cap and unified-agenda ordering tests.

## GREEN

- [ ] Add reminder store protocol, EventKit read implementation, DTOs, and AppModel lifecycle.
- [ ] Add local list filters and safe stale-id normalization.
- [ ] Add phased async queries, cache invalidation, month indicators, selected-date rows, agenda, and top groups.
- [ ] Add denied/restricted/loading/empty/error states and localization.

## VALIDATE

```bash
swift test --filter ReminderRead
swift test --filter Popover
swift test --filter Localization
swift test
swift build
./scripts/build-app.sh
```

Inspect packaged reminder permission strings in English and Simplified Chinese and smoke-test external Reminders.app changes.
