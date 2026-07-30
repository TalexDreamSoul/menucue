# EventKit reminders integration

## Goal

Integrate Apple Reminders into MenuCue's month calendar and today-anchored agenda, with independent authorization and the maximum public EventKit read/write field set that can be preserved reliably.

## Background

- MenuCue currently requests calendar-event access, creates events, shows event dots, and renders a seven-day event agenda.
- LunarBar demonstrates read-only reminder dots/details, but this task requires create, edit, complete/reopen, and delete.
- EventKit exposes reminder title, list, start/due components, completion, priority, location text, notes, URL, recurrence rules, and alarms. It does not expose Reminders.app tags, subtasks, attachments, or flag state.
- Shared `CivilDateKey`, overview-time-zone semantics, and month/day projections come from `07-30-lunar-month-calendar`.

## Requirements

### Authorization and filtering

- Request full reminder access independently and only after the user enables/invokes reminder features.
- Keep all calendar/event features usable when reminder access is denied or restricted, and provide a System Settings recovery action.
- Load reminder lists separately from event calendars, expose independent filtering, and store selected list identifiers locally only.
- Show writable capability per list/item and never expose mutation actions for read-only sources.

### Query and presentation

- Load incomplete selected-list reminders with bounded predicates appropriate to the visible timeline. When `Show Completed` is enabled, fetch all completed history progressively through newest-first completion-date windows; never issue one unbounded history query.
- Cancel stale requests and never block popover opening.
- Map date-only, floating, and time-zoned due components to shared civil dates without inventing dates for unscheduled reminders.
- Show only incomplete reminder indicators in month cells and keep them visually/accessibly distinct from event colors.
- Unify events and due reminders in the today-anchored seven-day agenda: all-day/date-only first, then timed items in deterministic order.
- Put incomplete overdue and unscheduled reminders in counted collapsible groups above the agenda; persist expansion locally.
- A timed reminder becomes overdue immediately after its effective due instant. A date-only reminder becomes overdue on the next civil day. Drive both transitions with a cancellable one-shot scheduler that recomputes after data/filter/time-zone/EventKit/time/wake changes.
- Hide completed reminders by default. Completion removes the row/indicator, offers short undo, and remains recoverable through `Show Completed` without restoring month indicators.
- Page records with non-nil `completionDate` backward through bounded windows; an empty window does not prove end of history.
- Expose a separate explicit, cancellable full completed query to supplement `completionDate == nil` records and deduplicate them against paged history. Never run that unbounded supplement automatically.

### Read/write scope

- Support create, edit, complete/reopen, and delete with confirmation.
- Reliably round-trip public fields: title, target list, start/due date components, completion state/date, priority, location text, notes, URL, recurrence rules, and supported alarms.
- Provide editors for simple and advanced EventKit recurrence initializer fields and relative, absolute, and geofence alarms where the provider accepts them.
- Treat recurrence `firstDayOfTheWeek` as read-only observed diagnostics; EventKit exposes no initializer that can set it.
- Preflight only public list-level writability and draft validity; EventKit does not expose complete item/geofence/provider capabilities.
- Patch a freshly fetched EventKit item and assign only collections the user actually changed. Never reassign untouched procedure alarms during unrelated edits.
- Re-fetch/compare the observed item after save. Report provider rejection or post-save adjustment explicitly; do not promise atomic rollback after EventKit has accepted a lossy/truncated write.
- If persisted list/item identifiers become invalid after full sync, remove stale selections or cancel the active edit, refresh, and never locate a replacement by title.

### Refresh and localization

- Refresh/coalesce on EventKit store changes and successful writes without closing the popover.
- Add English/Simplified Chinese permission, empty, denied, loading, editor, validation, capability, confirmation, undo, and accessibility text.

## Acceptance Criteria

- [ ] Reminder and event authorization tests prove independent request, denial, restricted, granted, and System Settings recovery behavior.
- [ ] Async fetch cancellation, list filtering, EventKit-change refresh, bounded incomplete queries, and newest-first completion-history window pagination remain deterministic and off the popover critical path.
- [ ] Date-only/floating/timed/unscheduled/overdue reminders map to the correct civil-date or explicit group across DST and overview time zones; timed items become overdue at the due instant and date-only items on the next civil day.
- [ ] Agenda ordering, month indicators, selected-date rows, scheduled due-instant/midnight overdue transitions, overdue/unscheduled groups, completed paging/supplement, and VoiceOver output distinguish reminders from events.
- [ ] Create/edit/complete/reopen/delete and undo pass through an injected store and verify observed results.
- [ ] All editable recurrence initializer fields and relative/absolute/geofence alarms round-trip in fixtures; observed `firstDayOfTheWeek` is read-only and may differ after rebuild.
- [ ] Unsupported procedure alarms survive unrelated field patches because untouched alarm collections are not reassigned.
- [ ] Read-only lists hide mutation controls; provider rejection or post-save adjustment yields an explicit observed-result warning without claiming rollback.
- [ ] Invalid persisted list/item identifiers are cleared/cancelled and refreshed without broadening filters or title-based mutation.
- [ ] Reminder list identifiers and UI expansion state remain local and never enter portable iCloud settings.
- [ ] Packaged English and Simplified Chinese InfoPlist resources contain `NSRemindersFullAccessUsageDescription` plus the legacy reminder usage key required by supported macOS versions, and authorization smoke tests pass.
- [ ] Focused tests, `swift test`, localization verification, `swift build`, and packaged app permission smoke tests pass.

## Task Map

- `07-30-reminders-read-timeline`: authorization, list discovery/filter normalization, bounded incomplete queries, month/selected-date projections, unified agenda, and overdue/unscheduled groups.
- `07-30-reminders-core-crud`: create/edit/delete for core fields, completion/reopen, undo, read-only handling, and observed-result saves.
- `07-30-reminders-advanced-fields`: recurrence/alarms, untouched procedure-alarm patching, provider adjustments, and all-history completion pagination.
- This parent owns the shared reminder DTO/draft contracts and final integration acceptance.

## Constraints

- Public EventKit only; no private Reminders framework/database access.
- Tags, subtasks, attachments, flags, collaboration controls, and exact Reminders.app parity are out of scope because EventKit does not expose them.
- Do not persist full reminder content outside transient cache or duplicate iCloud reminder data.
- Do not sync EventKit identifiers through MenuCue iCloud preferences.
