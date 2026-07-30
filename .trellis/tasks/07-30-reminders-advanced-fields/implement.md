# Implementation plan: reminder advanced recurrence alarms and history

## RED

- [ ] Add recurrence decoder/validator/builder golden fixtures for writable initializer inputs and read-only observed `firstDayOfTheWeek`.
- [ ] Add relative/absolute/geofence alarm fixtures, procedure-alarm lockout, and untouched-setter tests.
- [ ] Add provider rejection versus successful adjustment observed-result tests.
- [ ] Add completion-window continuation across empty ranges, overlap/dedup, cancellation, explicit nil-date full supplement, reopen, and render-cap tests.

## GREEN

- [ ] Add recurrence/alarm draft models, validation, UI sections, and dirty-field collection patching.
- [ ] Add provider result feedback and procedure-alarm read-only state.
- [ ] Add bounded completed-history loader, pagination UI, and reopen refresh.

## VALIDATE

```bash
swift test --filter ReminderAdvanced
swift test --filter ReminderCRUD
swift test --filter Localization
swift test
swift build
./scripts/build-app.sh
```

Smoke-test recurrence, multiple alarms, provider rejection, procedure-alarm preservation, and progressively older completed pages in a disposable list.
