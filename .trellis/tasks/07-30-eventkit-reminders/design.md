# Design: EventKit reminders integration

## Service boundary

Add an injected reminder store protocol around `EKEventStore` so pure logic and write behavior are testable without real user data.

`ReminderService` owns:

- reminder authorization/status and System Settings recovery URL
- reminder-list discovery and writability
- cancellable asynchronous fetch for selected lists
- save/remove operations and observed-result re-fetch
- EventKit store-change observation

`AppModel` owns published projections and settings mutations. SwiftUI does not hold `EKReminder` references or call EventKit directly.

## Models

- `ReminderInfo`: immutable display projection with stable runtime identity, list metadata, due/start semantics, completion, priority, detail fields, recurrence/alarm summaries, and writability.
- `ReminderDraft`: editable scalar fields plus explicit dirty flags for recurrence and alarms; it never owns an opaque collection that is automatically written back.
- `ReminderRecurrenceDraft`: typed EventKit frequency/interval/end and advanced BY* fields.
- `ReminderAlarmDraft`: relative, absolute, or geofence alarm editing state; provider support may only be known after save.
- `AgendaItem`: enum projection for event or reminder with shared civil-date/all-day/effective-time ordering keys and type-specific actions.

EventKit identifiers are runtime/cache locators, not durable cross-device identities.

## Fetch and cache

Use `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)` for bounded visible/timeline ranges plus a separate unscheduled strategy. Cancel superseded requests and project to lightweight DTOs off the main actor where API safety permits. `Show Completed` pages records with non-nil completion dates through newest-first, non-overlapping windows. Empty windows do not prove end-of-history. A separate explicit, cancellable all-completed predicate supplements nil-completion-date items and deduplicates them against paged rows; it never runs automatically. Reminder content is never serialized.

Cache keys include selected list ids, loaded completion windows, full-supplement state, overview time zone, and EventKit revision. Store-change bursts coalesce into one refresh. Normalize missing persisted list ids against current discovery: remove stale ids, preserve explicit remaining selections, and never broaden to every list silently.

A `ReminderDueScheduler` maintains the earliest upcoming timed due instant and next overview civil midnight as cancellable one-shot deadlines. Fetch/filter/time-zone/store/significant-time/wake changes recompute them; passing a deadline while asleep triggers immediate reprojection on wake.

## Date semantics

Preserve Gregorian `DateComponents` and optional component time zone. Components with no hour, minute, and second are civil-date reminders. Floating timed components use the overview time zone for presentation. Explicitly time-zoned components convert to overview time zone. Nil due date means unscheduled. A timed reminder becomes overdue after its due instant; a date-only reminder becomes overdue on the next civil day.

Completed items never contribute month indicators. `Show Completed` affects rows only and combines bounded dated-completion pages with the user-triggered nil-date supplement.

## Editor

Use a focused reminder sheet with standard controls and progressive sections:

- Basics: title, list, completion, priority
- Schedule: start, due date/time, floating/time-zone interpretation
- Repeat: simple presets and advanced writable EventKit initializer fields/end; show `firstDayOfTheWeek` read-only
- Alerts: relative, absolute, and geofence alarms with save-time provider feedback
- Details: location text, notes, URL
- Destructive delete command with confirmation

Do not erase an unsupported existing rule/alarm merely because the UI cannot alter it. Fetch a fresh EventKit item immediately before save and patch scalar fields. Assign `recurrenceRules` or `alarms` only when the corresponding editor is dirty. If an existing procedure alarm is detected, disable alarm editing and leave the collection untouched; procedure alarms are never created or modified.

Save flow is `validate draft -> check current list writability -> fetch fresh item -> patch dirty fields -> save -> re-fetch -> compare observable fields -> report exact result`. Public API cannot preflight every provider/geofence limit. A save error leaves the old item; a successful but adjusted save is reported as provider-adjusted and is not described as rolled back. If the item identifier is invalid, cancel and refresh rather than matching by title.

## Completion and undo

Completing/reopening is an EventKit save. On successful completion, optimistically remove the row only after save confirmation and retain enough transient information for a short undo action that reopens the same item. If the item cannot be found after an external sync, report that undo is unavailable instead of recreating a duplicate.

## Permissions and packaging

Use current macOS full-access reminder APIs with availability handling. Package and inspect localized `NSRemindersFullAccessUsageDescription` plus the legacy `NSRemindersUsageDescription` needed for supported deployment targets. Calendar access remains independent and must not be re-requested as part of reminders onboarding.

## Child boundaries

Read/timeline, core CRUD, and advanced recurrence/alarm/history work execute in separate child tasks. This design owns their DTO/draft contracts and integration behavior.

## Performance and privacy

Never log reminder titles, notes, locations, URLs, or alarm payloads. Log only operation kind, list/item writability, result class, and counts. Avoid file persistence of reminder content and avoid whole-store fetches when the user selected a subset of lists.
