# Design: reminder authorization and read timeline

Wrap EventKit with an injected store protocol returning immutable `ReminderInfo` projections. `AppModel` owns generations and publication; views never hold `EKReminder`.

Fetch phases:

1. bounded incomplete due range for today plus seven days
2. overdue incomplete range ending at current instant/civil boundary as appropriate
3. lazy all-incomplete selected-list fetch only when unscheduled data is requested, then filter nil due components

EventKit has no unscheduled-only predicate, so phase 3 is asynchronous, cancellable, selected-list-scoped, render-capped, and excluded from initial open latency. Store-change notifications invalidate all fetched EventKit objects and start a coalesced new generation.

Normalize list ids against current lists. If explicit selections vanish, remove only those ids and show filter remediation; do not fall back to all lists.

`AgendaItem` provides common civil date, all-day/date-only, effective time, type, accessibility, and stable runtime id. Completed reminders are excluded in this child.

A `ReminderDueScheduler` uses injected clock/scheduling boundaries. It schedules the earliest future timed due instant and next overview civil midnight, cancels/recomputes on generation/filter/time-zone/EventKit/significant-time/wake changes, and immediately reprojects when a deadline passed during sleep or clock movement.
