# Design: calendar and lunar calendar fusion

## Scope and ownership

This parent design integrates three child deliverables around one shared civil-date contract:

- `07-30-lunar-month-calendar`: month presentation, lunar/solar-term/festival context, event date semantics, and refresh lifecycle.
- `07-30-statutory-holiday-data`: canonical holiday feed, client cache, markers, and user overrides.
- `07-30-eventkit-reminders`: reminder authorization, query/write services, editor, and unified agenda.

The parent does not own a second implementation. It owns cross-child contracts, dependency order, information architecture, and final integration verification.

## Shared domain contracts

Introduce small value models instead of extending SwiftUI views with raw `Date`, EventKit objects, and JSON dictionaries.

### CivilDateKey

A `CivilDateKey` is a Gregorian `year-month-day` interpreted in an explicit calendar reference time zone. It is the shared key for month cells, selected-date state, statutory schedules, and custom overrides.

- Construct it only through a Gregorian calendar with an explicit time zone.
- Serialize it as strict `YYYY-MM-DD` only at persistence/feed boundaries.
- Do not use UTC-midnight `Date` values as civil-date identifiers.
- Keep the derivation time-zone identifier alongside presentation/query context, not inside statutory feed keys.

### CalendarDayPresentation

A month cell consumes one immutable projection containing:

- civil date and whether it belongs to the displayed month
- Gregorian day and today/selected/weekend state
- compact and full lunar presentation
- optional traditional festival and solar term
- optional statutory status and whether it is user-overridden
- event marker colors
- incomplete reminder marker state
- one complete accessibility description

The view renders this projection and does not recalculate calendars, decode feed data, or inspect EventKit types.

### Date context providers

- `LunarDateProvider`: Foundation Chinese-calendar conversion and localized presentation.
- `SolarTermStore`: read-only versioned 1901-2100 resource lookup.
- `TraditionalFestivalResolver`: independently implemented 12-festival rules.
- `StatutoryScheduleStore`: resolved official/custom status plus source metadata.
- `CalendarService`: EventKit event authorization, bounded range query, writes, and overlap projection.
- `ReminderService`: EventKit reminder authorization, asynchronous range query, writes, and capability-safe projections.

## Time-zone and date semantics

The overview time zone drives Gregorian month construction, lunar conversion, timed event/reminder grouping, and day rollover. Solar terms are the exception: they are cultural labels fixed to the source table's `Asia/Shanghai` civil dates and never move when overview time zone changes.

Timed events convert to the overview time zone. Multi-day and cross-midnight events occupy every intersecting civil date. EventKit returns all-day event `Date` values using the system default time zone rather than exposing source date components. Capture that civil key immediately at fetch time, preserve it by default, and pad bounded queries by two days on each side. An explicit portable setting may regroup all-day events by overview time zone. Month dots and selected-date rows use the same projection.

Reminder start/due `DateComponents` preserve their calendar and optional time-zone/floating semantics. Date-only reminders map to their component civil date. Timed reminders map through their declared or overview time zone. Missing due dates remain unscheduled and never receive a synthetic day.

## Presentation architecture

### Status item

The status item does not change in this MVP. Lunar status text and two-line layouts remain a separate later feature.

### Month grid

Keep the existing 42-cell structure and configured week rules. Give each cell stable height for:

1. primary Gregorian day
2. one compact secondary line with priority `festival > solar term > lunar date`
3. event/reminder indicators

A separate compact corner marker communicates statutory `holiday` or `workday`; it never displaces lunar text. Fixed dimensions and truncation must prevent hover, selection, larger text, or localization from shifting the grid.

### Selected-date detail

Show full Gregorian/lunar context, sexagenary year, solar term/festival, statutory status/source, events, and reminders. Holiday override editing is inline. Reminder editing may use a focused sheet because the public EventKit field set cannot fit safely in a compact row.

### Unified agenda

The seven-day agenda remains anchored to today. Each day groups all-day/date-only items first and timed items chronologically, with events and reminders distinguished by icon, semantics, color ownership, and actions. Timed reminders move to the overdue group after their due instant; date-only reminders move on the next civil day. Incomplete overdue and unscheduled reminders appear in counted collapsible groups above the agenda. Completed reminders are hidden by default and have short-lived undo. `Show Completed` pages backward through non-empty and empty completion-date windows without treating an empty window as end-of-history. A separate explicit, cancellable full completed query supplements records whose `completionDate` is nil and deduplicates against paged results.

## Lunar and solar-term data

Use Foundation `.chinese` for lunar month/day and leap-month state. Use localized `DateFormatter` presentation for the sexagenary year; formatted text is never parsed or persisted.

The solar-term resource contains exactly 24 `Asia/Shanghai` civil dates per Gregorian year from 1901 through 2100, source metadata, format version, and an integrity digest. It intentionally models Chinese cultural dates rather than astronomical instants projected into the overview time zone. Missing/out-of-range data degrades to lunar date only.

The independent festival resolver includes Spring Festival, Lantern Festival, Longtaitou, Dragon Boat, Qixi, Ghost Festival, Mid-Autumn, Double Ninth, Winter Clothes Day, Xiayuan, Laba, and Lunar New Year's Eve. Fixed festivals ignore leap months. New Year's Eve is the civil date whose next lunar date is non-leap month 1 day 1.

## Statutory data supply chain

### Release pipeline

Upstream adapters run outside the application and normalize candidate records into typed civil-date statuses. Inputs may include official government notices and LunarBar-compatible JSON. An official notice is authoritative; third-party sources only corroborate or flag anomalies.

Pipeline flow:

`fetch -> decode source adapter -> normalize -> validate dates/status -> compare -> block conflicts -> human approve official resolution -> build canonical manifest -> sign -> publish`

The canonical manifest contains schema version, monotonically increasing revision, publication time, `completeYears`, `validThrough`, coverage range, source references, per-record provenance, and holiday/workday records. Canonical bytes are UTF-8 JSON generated with sorted keys, deterministic array ordering, RFC 3339 UTC second-precision timestamps, defined escaping, and no trailing newline. A detached signature envelope binds algorithm, key id, manifest revision, SHA-256 digest, and base64 signature to those exact bytes. A dedicated Ed25519 data key signs the manifest; the private key exists only in the publishing environment and the app embeds trusted public keys.

### Client update

The app contacts only the canonical MenuCue feed on a delayed, jittered weekly schedule and explicit manual refresh. It uses conditional requests, response-size and timeout limits, validates HTTP/content type, signature, schema, revision, coverage, strict dates, known status values, and record uniqueness, then writes atomically. Invalid/regressive updates leave the last-known-good cache untouched.

Resolution precedence is:

`user override > validated cached canonical feed > bundled last-known-good > unavailable`

For ordinary external changes, compare generation first: higher replaces the complete lower-generation envelope; lower remote data is rejected and repaired by writing back higher local data; equal generations merge by deterministic `(modifiedAt, origin)` and write back the union. Individual tombstones are permanent.

Existing first-merge/account-change source decisions remain meaningful: choosing iCloud or This Mac promotes that chosen whole map to `max(localGeneration, cloudGeneration) + 1`, persists it locally, and exports it as authoritative. The override field executes this specialized path before generic whole-field outer-timestamp rejection. Enforce an encoded-size budget and keep local behavior available if cloud export pauses.

## Reminder boundary

EventKit exposes title, list, start/due components, completion, priority, location text, notes, URL, recurrence rules, and alarms. It does not expose Reminders.app tags, subtasks, attachments, or flag state.

The editor must round-trip any recurrence/alarm shape it claims to edit. It patches a freshly fetched `EKReminder`; untouched recurrence/alarm collections are never reassigned, which preserves procedure alarms during unrelated edits. Public preflight is limited to list writability and draft validity. Provider/geofence limits may only surface as save errors or observed post-save adjustments, which are reported explicitly without promising atomic rollback. Invalid list/item identifiers after full sync abort mutation and trigger filter/row refresh; title matching is forbidden. Calendar and reminder permissions remain independent.

## Settings and persistence

Portable fields:

- lunar display enabled
- mainland statutory markers enabled
- all-day event date policy
- per-date custom statutory override map with permanent tombstones and reset generation

Device-local fields:

- selected EventKit calendar/list identifiers
- reminder authorization/runtime state
- agenda expansion and `Show Completed` UI state
- canonical feed cache, validators, status, and last-check metadata

Initial lunar display is on for `CN`, `HK`, `MO`, `TW`, and `SG`; initial mainland statutory markers are on only for `CN`. Defaults are derived once when keys are absent and then persisted. Region changes never overwrite explicit settings.

## Refresh and caching

Observe EventKit store changes, calendar-day changes, system/overview time-zone changes, locale changes, significant time changes, and wake. Each notification invalidates only affected caches and coalesces refreshes on the main actor.

A `ReminderDueScheduler` owns one cancellable timer for the earliest upcoming timed reminder due instant and one for the next overview civil midnight. Refresh/filter/time-zone/store/time/wake changes recompute both. If wake or clock movement passes a deadline, reproject immediately before scheduling the next one.

Use bounded visible-month plus seven-day query windows. Build pure date projections outside the critical popover-open path, then publish immutable results on the main actor. Cache keys include visible month, overview time zone, week settings, lunar/statutory preferences, feed revision, override revision, EventKit revision, and reminder filter revision.

## Failure and rollback

- Lunar/solar-term failure: show Gregorian date; never block the popover.
- Statutory update failure: retain last-known-good data and expose stale/unavailable status.
- Event/reminder denial: preserve all non-EventKit calendar features and provide a System Settings recovery action.
- Unsupported reminder mutation: report the save error or observed provider-adjusted result; never promise rollback after a successful EventKit write.
- Performance/layout regression: independently disable lunar secondary lines, statutory markers, or reminder integration through stored feature settings without affecting the status item.

No migration deletes existing EventKit selections or calendar data.
