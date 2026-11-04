# Unified anchor time zone

User approved the previously reviewed analysis and implementation on 2026-11-03.

## Requirements
- The existing display-zone selection becomes the sole anchor time zone for internal civil dates, reminders, calendars, automatic appearance and time text.
- Preserve the user's existing overviewTimeZoneID selection and iCloud wire format. Remove independent appearance-zone configuration.
- Daily reminders, hourly windows, lid thresholds and deduplication use the anchor calendar; changes apply immediately without restarting.
- Reminder and quick-event editors interpret, display and save time in the same zone.
- World clocks remain independent; assigning an anchor from Overview must be explicit. System-zone settings and source data retain their meaning.
- Keep absolute timestamps, retry intervals, source all-day dates and recorded log offsets intact.

## Acceptance
- System Los Angeles / anchor Shanghai fires at Shanghai 11:00, not Los Angeles 11:00.
- Local changes, relaunch and iCloud changes preserve one choice and refresh consumers.
- Cross-midnight and DST cases do not emit duplicate daily reminders or loop hourly windows.
- Legacy preferences/cloud values still decode, and carousel reordering does not affect anchor fallback.
- Verify the actual app surface plus an isolated scheduler/outbox smoke without sending real notifications.
