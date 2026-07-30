# Reminder core CRUD and completion

## Goal

Add safe create/edit/delete plus complete/reopen/undo for core reminder fields on top of the frozen read/timeline service.

## Requirements

- Depend on `07-30-reminders-read-timeline` DTOs, authorization, filters, and refresh lifecycle.
- Edit title, destination list, start/due components, completion state/date, priority, location text, notes, and URL.
- Validate title/components/URL/priority and current destination-list writability.
- Fetch a fresh item before editing, patch only changed core scalar fields, save, re-fetch, and report observed values.
- Abort if list/item identifiers became invalid; refresh and never locate a replacement by title.
- Support create, edit, complete, reopen, delete with confirmation, and short-lived completion undo.
- Read-only lists expose no mutation controls.
- Keep recurrence/alarm collections untouched and out of this editor stage.

## Acceptance Criteria

- [ ] Core create/edit fields round-trip through an injected store and observed-result comparison.
- [ ] Invalid drafts and read-only destinations never call save.
- [ ] Stale identifiers cancel safely without duplicate/title fallback.
- [ ] Completion hides the item only after save, undo reopens the same item when available, and unavailable undo does not recreate it.
- [ ] Delete requires confirmation and external EventKit changes dismiss/refresh stale editors.
- [ ] Untouched recurrence/alarm collections are never assigned.

## Constraints

- No recurrence/alarm editing or completed-history browsing.
- No persistence/logging of reminder content.
