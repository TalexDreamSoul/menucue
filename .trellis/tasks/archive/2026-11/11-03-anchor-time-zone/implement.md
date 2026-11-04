# Implementation

1. Canonical model/persistence/cloud and appearance consumers (model slice).
2. UI/calendar consumers and localization (UI slice).
3. Scheduler/AppModel/alert-time integration (integration owner).
4. Migrate existing tests and add timezone/DST/date-line regression cases (Tester slice).
5. Once all edits settle, run Swift build/focused tests, isolated real outbox smoke and native app UI verification.
6. Update existing change/spec records and remove throwaway artifacts.

Shared APIs: AppSettings.anchorTimeZoneID / anchorTimeZone / anchorCalendar; formatDate(_:date:time:). ReminderScheduler.start(settings:deviceName:timeZone:) and update(settings:deviceName:timeZone:) require explicit zone. QuickEventDraft(startDate:calendarID:timeZone:) requires explicit zone. AlertTemplateContextBuilder.values(...,timeZone:) requires explicit zone. PreferenceSyncStatus.message(timeZone:) replaces its property when needed.

All workers skip build/lint/tests/formatters mid-flight. Parent is integration owner. Production slices never edit Tests; Tester owns all test changes. SourceKit references attempted and failed with standard-library loading error; text/structural fallback allowed.

## Verification completed

- `swift build --scratch-path /tmp/menucue-anchor-build` passed.
- `swift test --scratch-path /tmp/menucue-anchor-build` passed: 753 XCTest cases and 6 Swift Testing cases, zero failures.
- `swift scripts/verify-localizations.swift Sources/MenuCue/Resources/en.lproj/Localizable.strings Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings` passed: 1,537 matching keys and format arguments.
- Linked the actual debug objects into a throwaway smoke executable (excluding only the production entry point). With process `TZ=America/Los_Angeles` and explicit anchor Shanghai, the production scheduler/outbox queued zero events at `2026-11-03T02:59:59Z`, one at `03:00:00Z` (Shanghai 11:00), and still one at `19:00:00Z` (Los Angeles 11:00). The dispatcher stayed paused and delivery stayed pending.
- Opened the actual `TimeZoneSettingsView` and `ReminderSettingsView` under an isolated SettingsStore. Native screenshot confirmed separate Anchor Time and macOS zone cards; saved and reopened the lunch reminder with 11:00 preserved. Evidence: `/tmp/menucue-anchor-time-ui.png`, `/tmp/menucue-anchor-reminder-reopened.png`.
- The UI smoke did not replace the installed app, write real calendar events, or enable delivery/system appearance/hotkeys. Closed normally; removed throwaway source, response file and executable. Build products remain outside the repository in `/tmp`.
- Full-suite verification exposed real notification startup in unrelated AppModel test fixtures. Fixed their pre-init isolated settings, not production notification code. Removed an obsolete wording-pinned localization test and resolved the helper test product beside the actual test bundle rather than hard-coding `.build/debug`.
- Updated README and the existing frontend state-management specification. Existing user-owned session archive and `.build` symlink were left unchanged. No commit, push, installation or release was performed.
