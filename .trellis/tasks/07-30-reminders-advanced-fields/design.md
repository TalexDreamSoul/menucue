# Design: reminder advanced recurrence alarms and history

Extend `ReminderDraft` with separate recurrence/alarm sections and dirty flags. Decode all observable EventKit fields for display. Build a replacement collection only when the user edits that section; otherwise the fresh item's collection remains untouched.

A procedure alarm is not round-trippable through public API. Its presence makes the alarm section read-only while allowing core scalar patches on the fresh object.

Recurrence editor covers writable initializer inputs: frequency, interval, end count/date, days of week/month/year, months/weeks, and set positions. `firstDayOfTheWeek` is read-only observed diagnostics because EventKit exposes no initializer parameter for it. Validation rejects nonsensical/unsupported combinations before save; post-save comparison reports EventKit's observed first-day value.

Completed history uses `predicateForCompletedReminders` with an initial recent window, then contiguous older completion-date windows on explicit load. Keep loaded ranges and ids to deduplicate; an empty window does not prove end-of-history, so navigation continues until a documented lower calendar bound or the user stops. A separate explicit, cancellable all-completed predicate supplements completed reminders whose completion date is nil and deduplicates them against paged results. Filter/time-zone/EventKit revisions cancel pages and the supplement. Rows remain in memory only.
