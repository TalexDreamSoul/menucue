# Reminder authorization and read timeline

## Goal

Add independent reminder authorization, list filtering, date-safe read projections, month indicators, and a unified event/reminder agenda without blocking the popover.

## Requirements

- Request full reminder access independently and package localized current/legacy usage descriptions.
- Discover reminder lists and normalize persisted ids; remove missing ids without silently broadening an explicit filter.
- Fetch the seven-day due range first with a bounded incomplete predicate.
- Load overdue reminders asynchronously with an open-ended-before-now predicate; load all-incomplete selected-list data for unscheduled filtering only after reminder UI is enabled/needed, never on the initial popover critical path.
- Cancel stale requests, coalesce EventKit changes, cap rendered rows, and never persist reminder content.
- Map date-only, floating, explicit-time-zone, timed, overdue, and unscheduled reminders to shared civil-date projections.
- Move timed reminders to overdue after the due instant and date-only reminders on the next civil day through a cancellable one-shot due/midnight scheduler.
- Add distinct incomplete month indicators, selected-date rows, unified seven-day agenda, and counted collapsible overdue/unscheduled groups.

## Acceptance Criteria

- [ ] Authorization states and System Settings recovery are independent from calendar events.
- [ ] Bounded agenda fetch publishes before lazy overdue/unscheduled work; stale generations cannot overwrite current filters.
- [ ] Large selected-list fixtures remain responsive and rendering caps are explicit.
- [ ] Date/time-zone/DST and overdue rules are deterministic; scheduler tests cover ordinary deadlines, cancellation, sleep past due, clock rollback, and overview time-zone change.
- [ ] Missing list ids clear safely without selecting every list.
- [ ] Events and reminders are visually/accessibly distinct.
- [ ] Packaged English/Simplified Chinese reminder usage descriptions are inspected by tests.

## Constraints

- Read path only; no mutation or completed-history pagination.
- Public EventKit only and no disk persistence of reminder content.
