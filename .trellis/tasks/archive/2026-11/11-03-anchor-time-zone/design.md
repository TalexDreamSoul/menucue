# Design

## Canonical state
AppSettings.anchorTimeZoneID replaces overviewTimeZoneID in memory. anchorTimeZone resolves the IANA ID with system-only fallback; anchorCalendar is Gregorian in that zone. Keep the local overviewTimeZoneID storage key and legacy iCloud DTO cases as wire compatibility only. Remove appearanceTimeZoneID and appearanceTimeZone from runtime; remove obsolete stored appearance key on save.

Use AppSettings.formatDate(_:date:time:) for common visible dates, preserving absolute Date values. Invalid selection exposes a visible fallback warning, never consults world-clock order.

## Integration
ReminderScheduler.start/update receive required timeZone: TimeZone and replace their calendar before tick. Preserve recurrence baselines and fired history across changes; snapshot occurrence keys before asynchronous enqueues. Daily identity stays civil day, with durable fired-day state for date-line changes; hourly identity stays absolute occurrence. Hourly windows must stop at the anchor day's end even across midnight and repeated DST hours. Daily missing times follow Foundation nextTime; repeated times choose first.

AppModel passes anchor settings on startup, all edits and cloud imports; invalidates appearance schedule only when anchor changes; gives alert monitoring an explicit zone for event.time. No global mutable timezone and no system preference writes.

Editors receive the anchor zone explicitly, including draft hour rounding. Environment calendar/timeZone is set on relevant SwiftUI roots and editors. Historical diagnostics aggregate current-day views from absolute event instants in anchor calendar while recorded history buckets remain unchanged.

## Boundaries
EventKit source all-day interpretation, historical recorded offsets, machine-readable UTC fields, durations, retries, world-clock and macOS zone controls retain original meaning. No networking credentials or notification sends in smoke verification.
