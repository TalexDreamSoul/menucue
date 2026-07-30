# Reference project and platform research

Research date: 2026-07-29

## Audited revisions

- Itsycal: `sfsam/Itsycal@8d7676d2269a37c926ecf79a5095944559beeea3`
- LunarBar: `LunarBar-app/LunarBar@7160e561bf6d13c68678e12585c768616463f5e4`
- MacCalendar: `bylinxx/MacCalendar@46702370f17b7b387411ad0b3de718366e08669d`

## Comparison

| Area | Itsycal | LunarBar | MacCalendar | MenuCue direction |
| --- | --- | --- | --- | --- |
| Primary structure | Month grid plus expandable agenda | Dense 6x7 month grid with hover detail | Month grid, selected-date detail, event list | Keep existing month grid; add selected-date context without replacing the seven-day agenda |
| EventKit | Strong range cache, EventKit-change and system-change refresh | Read-only events/reminders, async month loading | Selected-day event detail and mutation | Preserve MenuCue creation; add bounded month cache and complete refresh notifications |
| Navigation | Strong keyboard, trackpad, jump-to-date | Keyboard month/year navigation | Direct year/month entry | Add keyboard month/day navigation later without hiding basic controls |
| Week numbers | Optional ISO week number | None | Optional week column | Preserve MenuCue's existing configurable week behavior |
| Lunar calendar | None | Foundation Chinese calendar | Foundation plus custom calculations | Use Foundation for lunar date, leap month, and localized sexagenary year |
| Solar terms | None | Precomputed 1901-2100 table | Approximation formula | Use a versioned, sourced 1901-2100 table; never silently approximate |
| Traditional festivals | None | Rules with cell-label priority | Fixed Gregorian/lunar rules | Independently implement a small tested traditional-festival ruleset |
| Statutory schedules | None | Bundled annual data plus update/override | Bundled 2015-2026 data | Defer until an authoritative update and signature lifecycle is designed |
| Security | Broad legacy configuration | Sandboxed and permission-scoped | Main app not sandboxed | Keep permissions scoped and request EventKit access only when needed |
| License | MIT | MIT | No explicit license | Ideas are references; do not copy MacCalendar code or data |

## Platform verification

A Swift 6.2.3 probe on macOS 26.5 confirmed:

- `Calendar(identifier: .chinese)` returns lunar `month`, `day`, `isLeapMonth`, `era`, and cyclical `year`.
- The Chinese-calendar `year` is a sexagenary-cycle position, not a Gregorian year. It must not be persisted or displayed as an absolute year.
- With `zh_CN`, a long Chinese-calendar formatter can render localized lunar month/day, leap month, and sexagenary year.
- Foundation does not expose solar terms, traditional festivals, statutory holiday/workday schedules, zodiac, sexagenary month/day, or almanac auspiciousness as calendar components.
- The result depends on `Calendar.timeZone`. At the same absolute instant, Shanghai can already be lunar New Year's Day while UTC and Los Angeles remain the prior lunar date.

Recommended deterministic boundary:

- Set both `Calendar` and `DateFormatter` to the overview time zone.
- Build civil-date test inputs at local noon unless the test explicitly targets midnight.
- Treat formatted strings as presentation only; do not parse or persist them.
- Support sourced solar terms from 1901 through 2100 and fall back to lunar date only outside that range.

## Current MenuCue gaps discovered

- The existing month view already renders 42 cells, configurable week starts, week numbers, and up to three event dots.
- There is no lunar, solar-term, traditional-festival, statutory-schedule, or leap-month presentation model.
- Calendar refresh does not currently cover `EKEventStoreChanged`, civil-day rollover, locale/time-zone changes, significant clock changes, and wake from sleep.
- Event dots currently group by start date, so cross-midnight and multi-day events can disappear from later covered dates.
- Extending EventKit queries from a short agenda to a whole visible month requires bounded caching and must stay off the popover-opening critical path.
- All-day events need civil-date semantics distinct from timed-event time-zone conversion.

## LunarBar holiday update audit

LunarBar's reusable product pattern is:

1. Load bundled JSON from `Resources/Holidays`.
2. Load cached JSON from the app cache directory.
3. Load user JSON from the Documents directory, with user data taking precedence.
4. Fetch `https://github.com/LunarBar-app/Holidays/raw/main/mainland-china.json` two seconds after launch and weekly thereafter.
5. Accept HTTP 200 plus a top-level `[String: [String: Int]]` shape, write atomically, then reload.
6. Expose manual fetch, enable/disable, open customization directory, and reload controls.

The mechanism should not be copied unchanged:

- The updater has no signature or hash verification, schema version, declared coverage, payload size limit, `ETag`/`Last-Modified` handling, freshness metadata, or explicit rollback record.
- It validates only the broad dictionary shape; arbitrary years, invalid month/day keys, and unsupported integer values can enter the cache.
- Bundled data is searched before cached data, so an online correction cannot override an existing bundled date. User-defined data does take precedence.
- The separate `LunarBar-app/Holidays` repository has no explicit license. Its published data endpoint is not an acceptable long-term redistribution or trust boundary for MenuCue.
- LunarBar's main repository is MIT and contains a bundled holiday file, but direct reuse would still require attribution and would not solve future data provenance.

MenuCue should independently implement the same high-level layering with typed records and this precedence:

`user override > validated current feed > bundled last-known-good > unavailable`

The feed should be maintained by MenuCue from authoritative government notices, signed with a dedicated data-signing key, and distributed from a MenuCue-controlled GitHub release or static endpoint. Download activation must require a valid signature, supported schema, monotonic revision, valid Gregorian dates, known status values, declared coverage, and atomic persistence. Conditional requests and a weekly jittered check avoid unnecessary GitHub traffic. The existing Sparkle updater remains app-binary-only; holiday data uses a separate service and status model.

## Legal boundary

Itsycal and LunarBar use the MIT license. Substantial source reuse requires preserving their copyright and license notices, and bundled third-party code still needs separate review. MacCalendar has no repository license or GitHub-detected license; public source visibility is not permission to copy, modify, or distribute its code, resources, or datasets.
