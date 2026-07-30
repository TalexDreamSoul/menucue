# Reminder advanced recurrence alarms and history

## Goal

Extend the core reminder editor with supported recurrence/alarm controls and progressive all-history completed browsing without silent EventKit data-loss claims.

## Requirements

- Depend on core CRUD dirty-field patching and the read timeline.
- Support simple presets and advanced public EventKit recurrence initializer fields/end conditions.
- Display observed recurrence `firstDayOfTheWeek` as read-only diagnostics; do not expose an editor because public initializers cannot set it.
- Support relative, absolute, and geofence alarms where EventKit/provider accepts them.
- Detect existing procedure alarms; disable alarm editing and leave the full collection untouched during unrelated saves.
- Assign recurrence/alarm collections only when that editor section is dirty.
- Preflight public validation/list writability only. Report provider save errors or observed post-save adjustment; do not promise rollback after successful lossy save.
- `Show Completed` pages reminders with non-nil completion dates through newest-first non-overlapping windows; empty windows do not terminate the search.
- Provide an explicit, cancellable all-completed supplement for records with nil completion dates, deduplicating against paged rows. Never run it automatically.
- Completed rows can reopen reminders but never add month indicators.

## Acceptance Criteria

- [ ] Editable recurrence initializer fields and relative/absolute/geofence alarms round-trip in fixtures; `firstDayOfTheWeek` remains read-only observed output.
- [ ] Unchanged recurrence/alarm collections are never assigned.
- [ ] Procedure alarms block alarm editing but survive unrelated core patches.
- [ ] Provider rejection and post-save adjustment have distinct outcomes and no false rollback claim.
- [ ] Completed history pages dated completions across empty windows; explicit full supplement finds nil-completion-date items, deduplicates, cancels safely, and never runs on initial open.
- [ ] Reopening a completed item refreshes current/history projections.

## Constraints

- No tags, subtasks, attachments, flags, private alarms, or exact Reminders.app parity.
- No automatic or ordinary unbounded all-history query. The only exception is the user-triggered, cancellable all-completed supplement used to recover records whose completion date is unavailable.
