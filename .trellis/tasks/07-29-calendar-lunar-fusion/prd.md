# Calendar and lunar calendar fusion

## Goal

Turn MenuCue's existing month grid and EventKit surface into a balanced daily calendar that answers three glanceable questions: what date is it, what cultural date context matters today, and what event is next. It must remain a compact menu-bar companion rather than a replacement for Calendar.app.

## Background

- MenuCue already has a 42-cell month grid, configurable first weekday and week numbers, EventKit event dots, a seven-day agenda, event creation, calendar filtering, an overview time zone, and English/Simplified Chinese localization.
- Itsycal validates the month-grid-plus-agenda structure, keyboard navigation, bounded EventKit caching, and comprehensive system-change refresh handling.
- LunarBar validates Foundation Chinese-calendar conversion, one-line cell-label priority, and source-controlled solar-term data.
- MacCalendar validates selected-day details and optional traditional-calendar menu-bar formatting, but it has no explicit source license and is reference-only.
- Calendar data remains owned by EventKit. MenuCue must not store iCloud credentials or create a parallel event database.
- This task is a planning child of `07-04-macos-status-clock`; implementation requires review of the final PRD, design, and implementation plan.

## Requirements

### Information architecture

- Keep the menu-bar title unchanged throughout the MVP. Lunar status-item text and two-line layouts are explicitly post-MVP.
- Add one optional secondary line to each month cell. Its display priority is traditional festival, then solar term, then compact lunar month/day text.
- Show statutory holiday/workday state as a separate compact `休`/`班` corner marker so it never replaces the lunar secondary line.
- Preserve the Gregorian day as the primary cell label and preserve up to three EventKit color dots without overlap.
- Show the selected date's full Gregorian date, lunar month/day including leap-month status, sexagenary year, applicable solar term or traditional festival, EventKit events, and due reminders for that civil date.
- Keep events and reminders visually and accessibly distinct in month indicators and selected-date groups.
- Keep the seven-day agenda anchored to today and unify events plus due reminders within each civil-date group. Selecting a historical or future month cell must not silently replace the agenda's range.
- Order timed events and reminders by their effective time; place all-day events and date-only reminders in the date's all-day group with distinct icons, row semantics, and completion affordances.
- Place incomplete overdue reminders and incomplete reminders without a due date in separate collapsible groups above the seven-day agenda. Show counts and persist each group's expanded state locally.
- Do not fold overdue or unscheduled reminders into today's civil-date group.
- Add independent lunar-calendar and mainland statutory-schedule toggles. Derive their initial values from system region only when each setting is absent, persist the result, and never overwrite an explicit user choice after a region change.
- Default lunar display on for mainland China, Hong Kong, Macao, Taiwan, and Singapore system regions. Default mainland statutory markers on only for mainland China.
- Keep the all-day event time-zone policy portable and eligible for field-level iCloud settings sync.
- Add visual per-date statutory-status editing to the selected-date detail. The available states are use official value, mark as holiday, mark as workday, and suppress the marker for this date.
- Apply user overrides after the signed canonical feed and bundled fallback. Show when an official value is overridden and provide one-command restoration to the official value.
- Keep custom overrides separate from downloaded datasets so a feed update cannot erase them and resetting one override cannot mutate cached source data.
- Do not require users to edit or place JSON files in the MVP.

### Calendar semantics

- Use the overview time zone as the explicit reference for Gregorian month construction, lunar conversion, timed-event grouping, and day rollover.
- Treat solar terms as fixed `Asia/Shanghai` civil-date labels from the sourced UTC+8 table; changing overview time zone must not shift their Gregorian date.
- For all-day events, capture the source civil date immediately after fetch using EventKit's system-default-time-zone semantics. Preserve that key by default and provide an explicit portable option to regroup by overview time zone.
- Pad visible EventKit queries by two civil days at both boundaries so all-day and timed events survive the maximum system/overview time-zone offset.
- Apply the selected all-day policy consistently to month-grid dots and selected-date event lists; one event must not appear under different dates on the two surfaces.
- Assign multi-day and cross-midnight events to every visible civil date they overlap, not only their start date.
- Request EventKit reminder permission independently and only when the user enables or invokes reminder functionality; calendar permission must not imply reminder permission.
- Support reminder creation, editing, completion/reopening, and deletion directly from the selected-date reminder group.
- Expose the maximum reliably round-trippable public EventKit field set: title, target reminder list, start and due date components including floating/all-day semantics, completion state, priority, location text, notes, URL, recurrence rules, and supported relative, absolute, or geofence alarms.
- Preserve recurrence and alarm collections by patching a freshly fetched `EKReminder` only for fields the user changed. If an existing procedure alarm is present, leave the alarm collection untouched during unrelated edits.
- Preflight only public list-level writability and draft validity. Provider/geofence limitations that EventKit does not expose are handled through save errors and observed-result reporting.
- Expose write actions only for reminders in writable lists; if an item/list identifier becomes invalid after sync, abort mutation, clear stale selection state, refresh, and never fall back by title.
- Allow filtering reminder lists independently of event calendars. Persist EventKit calendar/list identifiers locally only and exclude them from portable iCloud settings.
- Group reminders by due civil date using the same overview-time-zone policy. Date-only reminders become overdue on the next civil day; timed reminders become overdue immediately after their effective due instant. Incomplete reminders with no due date belong only to the unscheduled group.
- Hide completed reminders from month indicators and the primary timeline. Completing a reminder removes it after EventKit save succeeds and offers a short-lived undo action.
- `Show Completed` loads reminders with a completion date progressively through newest-first bounded windows. Because EventKit permits completed reminders with no completion date, expose a separate explicit, cancellable `Complete Unknown-Date History` action that performs one all-completed fetch and deduplicates results; never run it automatically on popover open.
- Validate reminder drafts before saving and refresh month indicators plus selected-date rows only after EventKit confirms the write.

### Lunar and holiday data

- Use `Calendar(identifier: .chinese)` and localized Foundation formatting for lunar month/day, leap month, and sexagenary year.
- Ship a versioned, provenance-documented 1901-2100 solar-term dataset instead of a low-accuracy approximation formula.
- Implement an independently tested 12-festival ruleset: Spring Festival, Lantern Festival, Longtaitou, Dragon Boat, Qixi, Ghost Festival, Mid-Autumn, Double Ninth, Winter Clothes Day, Xiayuan, Laba, and dynamically derived Lunar New Year's Eve.
- Match fixed festivals only in non-leap lunar months. Derive Lunar New Year's Eve from the following day's first lunar month rather than assuming the 29th or 30th day.
- Degrade outside the supported solar-term range to lunar date only, without a network request or a false result.
- Ship statutory holiday and make-up workday schedules as a separately versioned dataset produced from multiple upstream sources, with an online update path and a bundled last-known-good snapshot.
- Run all upstream retrieval, normalization, and conflict detection in a MenuCue-controlled release pipeline, not in each installed client.
- Treat an official government notice as the authoritative source. Third-party adapters, including LunarBar-compatible data, are corroboration and anomaly-detection inputs only.
- Block publication on any disagreement involving an authoritative record. Require a human reviewer to attach the official source reference and approve the resolved record before signing.
- Publish one signed, immutable dataset revision after conflict checks pass. The app downloads only this canonical feed and does not contact upstream providers directly.
- Define canonical encoding byte-for-byte, including UTF-8 JSON key/order/escaping/date/newline rules and the detached signature envelope's algorithm, key id, revision, manifest digest, and signature encoding.
- Include explicit `completeYears` and `validThrough` metadata so fresh, stale, and unavailable states are executable rather than inferred from download time.
- Validate downloads before activation; malformed, unsigned or unverifiable, regressive, or out-of-range data must be rejected without replacing the last-known-good snapshot.
- Mark statutory data as unavailable or stale outside its declared coverage instead of guessing. Network failure must not block the month grid or any lunar-calendar feature.

### Refresh, performance, and accessibility

- Refresh relevant calendar state on EventKit database changes, civil-day rollover, system or overview time-zone changes, locale changes, significant clock changes, and wake from sleep.
- Maintain a cancellable one-shot reminder deadline scheduler for the earliest upcoming timed due instant and next overview-time-zone civil midnight; recompute after data/filter/time-zone/EventKit/time/wake changes.
- Build and cache pure month-day presentation models off the popover's critical rendering path; opening the popover must not perform unbounded synchronous EventKit work.
- Keep Gregorian, lunar, solar-term, and traditional-festival calculation fully offline. Statutory holiday updates may use the network but must always have a bundled or cached last-known-good fallback.
- Provide English and Simplified Chinese labels, VoiceOver descriptions, and layouts that remain legible at the largest supported macOS accessibility text size.

## Acceptance Criteria

- [x] A comparison record documents Itsycal, LunarBar, and MacCalendar capabilities and license constraints.
- [ ] The status item remains visually unchanged with default settings.
- [ ] Enabling lunar display adds one stable secondary line to each month cell with the specified priority and no collision with event dots.
- [ ] Incomplete overdue and unscheduled reminders appear in separate counted, collapsible groups above the agenda and never alter today's date group.
- [ ] Reminder permission is requested independently, denial has a System Settings recovery path, and calendar/event functionality remains usable without reminder access.
- [ ] Users can create, edit, complete, reopen, and delete reminders across the supported EventKit field set; invalid drafts cannot write, read-only items cannot expose mutation controls, and deletion requires confirmation.
- [ ] Complex recurrence and alarm records round-trip without silent data loss when their collections are edited; unrelated edits patch a fresh EventKit object without assigning untouched alarm/recurrence collections.
- [ ] Provider rejection or post-save adjustment is detected and reported as the observed result; the product does not promise atomic rollback after EventKit accepts a lossy save.
- [ ] Completing a reminder hides it from primary rows and month indicators after save and offers undo. Completed history pages cover dated completions; the explicit cancellable full-history supplement finds and deduplicates completed reminders whose completion date is unavailable.
- [ ] Timed reminders move to overdue through the one-shot deadline scheduler after their due instant; date-only reminders move through the scheduled next civil midnight, including sleep and clock/time-zone changes.
- [ ] Reminder-list identifiers remain device-local and are excluded from iCloud portable settings.
- [ ] A user can visually mark a selected civil date as holiday, workday, hidden, or official; the month cell updates immediately, distinguishes custom state accessibly, and can restore the official value.
- [ ] Feed refreshes never erase custom overrides, and custom reset never mutates bundled or cached feed data.
- [ ] Custom override normal sync applies higher-generation replacement, rejects/repairs lower-generation remote data, and merges equal-generation per-date entries. First merge, account change, and explicit `Use iCloud`/`Use This Mac` promote only the chosen complete map to `maxGeneration + 1`. Generic outer-field LWW cannot skip this specialized path.
- [ ] All-day events preserve their source civil date by default; the optional overview-time-zone policy applies consistently to month-grid dots and selected-date event lists and persists across restart and portable settings sync.
- [ ] All 12 selected traditional festivals render on deterministic golden dates, do not duplicate in leap months, and resolve Lunar New Year's Eve for both 29-day and 30-day final lunar months.
- [ ] Solar-term data is fixed to `Asia/Shanghai` civil dates and has a documented source, version, 1901-2100 validity range, integrity test, and graceful out-of-range fallback.
- [ ] The client contacts only the canonical MenuCue feed; upstream adapters and conflict resolution run in the release pipeline and are tested independently.
- [ ] Multi-source statutory data is normalized into one deterministic record set with per-record provenance and explicit conflict handling; source order or network timing cannot change the result.
- [ ] Statutory data validates before activation, retains a bundled or cached last-known-good fallback, and exposes coverage/staleness without blocking the calendar.
- [ ] Official-source conflicts block publication until a human-reviewed resolution with an authoritative source reference is recorded; majority vote and newest-source wins are not permitted.
- [ ] Calendar state refreshes after EventKit, day, time-zone, locale, significant-time, and wake changes without closing and reopening the popover.
- [ ] Lunar display defaults on only for mainland China, Hong Kong, Macao, Taiwan, and Singapore when no stored choice exists; mainland statutory markers default on only for mainland China.
- [ ] English and Simplified Chinese localization parity and VoiceOver output are tested.
- [ ] All focused tests and the repository verification command pass before implementation is considered complete.
- [ ] The user reviews and approves the final PRD, design, and implementation plan before coding starts.

## Constraints

- Prefer Foundation, SwiftUI, AppKit, and EventKit; do not add a third-party runtime dependency for lunar conversion.
- Itsycal and LunarBar are MIT-licensed, but any copied implementation requires attribution and license preservation. Prefer independent implementation against Foundation and documented data sources.
- MacCalendar has no explicit license; do not copy its source code, resources, or datasets.
- Core date presentation must not depend on a network service; only statutory holiday freshness may depend on network access.

## Out of Scope

- Full Calendar.app event/account management or a second calendar database.
- Lunar text in the menu-bar title in the MVP.
- JSON-based holiday customization or folder-watching workflows.
- Bulk editing, recurring custom work schedules, or organization policy import in the MVP.
- Zodiac, reminder tags, subtasks, attachments, flag state, or any other model not exposed by public EventKit.
- Exact Reminders.app feature parity or private framework access.
- Widgets, astrology, fortune-telling, almanac auspiciousness, or religious calendars.

## Task Map

- `07-30-lunar-month-calendar`: own the civil-date model, lunar/solar-term/festival presentation, month-grid layout, EventKit event date semantics, refresh lifecycle, and lunar preference.
- `07-30-statutory-holiday-data`: integration parent for `07-30-holiday-publishing-pipeline`, `07-30-holiday-client-feed`, and `07-30-holiday-overrides-sync`.
- `07-30-eventkit-reminders`: integration parent for `07-30-reminders-read-timeline`, `07-30-reminders-core-crud`, and `07-30-reminders-advanced-fields`.
- This parent owns cross-child information architecture, shared civil-date contracts, dependency order, and final integration review.
