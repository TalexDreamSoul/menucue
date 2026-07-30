# Design: lunar month calendar and event semantics

## Boundaries

Create pure domain types before changing the view:

- `CivilDateKey`: strict Gregorian year/month/day value.
- `CalendarMonthContext`: visible month, overview time zone, first weekday, and week-number policy.
- `LunarDateInfo`: numeric lunar components, leap flag, compact/full localized text, and sexagenary-year presentation.
- `CalendarDayPresentation`: immutable month-cell/date-detail projection.
- `EventOccurrenceProjection`: one EventKit event mapped to every relevant civil date.

`StatusPopoverView` consumes projections only. Calendar arithmetic remains in focused services so statutory and reminder siblings can reuse the contracts.

## Data flow

1. `AppModel` owns selected month/date and requests a `CalendarMonthContext`.
2. A month builder creates 42 civil dates in the overview time zone.
3. `LunarDateProvider`, `SolarTermStore`, and `TraditionalFestivalResolver` enrich each date.
4. `CalendarService` queries the bounded 42-day visible range plus agenda range and projects events by overlap/all-day policy.
5. A presentation builder combines date context and event markers off the view body.
6. Immutable projections publish on the main actor and render without further date parsing.

## Lunar rules

Use an explicitly time-zoned `.chinese` calendar for numeric month/day/leap state. Use a similarly time-zoned Chinese `DateFormatter` only for localized full presentation. Do not persist cyclical years or parse formatted output.

Solar-term records are keyed by Gregorian `CivilDateKey` in the explicit reference zone `Asia/Shanghai` and include source/version metadata. They are cultural-date labels and never reproject when overview time zone changes. Resource initialization validates structure once. Festival rules match non-leap lunar month/day; New Year's Eve compares the following lunar day to non-leap month 1 day 1.

## Event semantics

Timed-event coverage uses half-open intervals and intersects each civil-day interval in the overview time zone. Zero-duration events map to their start civil date. EventKit exposes all-day starts/ends as `Date` values in the system default time zone, not source components; capture their civil keys immediately after fetch. Default membership uses the captured keys, while optional regrouping uses overview-time-zone intervals. Query the visible range with two-day padding on both boundaries, then project locally. The same projection feeds dots, selected-date rows, and agenda membership.

## Lifecycle and performance

Observe `EKEventStoreChanged`, `NSCalendarDayChanged`, system time-zone/locale/significant-time changes, overview setting changes, and workspace wake. Coalesce bursts, invalidate only affected keys, and publish on the main actor. Do not synchronously fetch an unbounded EventKit range during popover opening.

Cache keys include month, overview time zone, week settings, lunar preference, solar resource version, event-store revision, and all-day policy.

## UI

Keep a fixed cell geometry with Gregorian text, optional compact lunar line, and event indicators. On the first lunar day show the lunar month name; otherwise show lunar day. Festival replaces solar term, which replaces normal lunar text. Accessibility always includes full Gregorian and lunar context even when visual text is compact.

The selected-date detail expands full context and events. The status item remains unchanged.

## Migration

New scalar keys are presence-aware. If absent, derive lunar visibility once from `CN/HK/MO/TW/SG`, persist it, and then respect the stored value. Add the scalar to the existing portable field projection with backward-compatible decoding.
