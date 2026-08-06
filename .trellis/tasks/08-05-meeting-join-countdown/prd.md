# Meeting join and next-event countdown

Parent: `08-05-menubar-ux-system-control`

## Goal

Turn MenuCue's agenda from a list you read into an action you take: show how long until the
next meeting, and let the user join it in one click.

## Background

The request that produced this task was "integrate Lark (Feishu) calendar". The parent task
records why a first-party Lark API integration was deferred — a distributed desktop app cannot
embed `app_secret`, so it needs PKCE support or a relay service, for data the user can already
surface by subscribing the Lark calendar's ICS link into macOS Calendar.

What the request is actually reaching for is the thing Dato leads with: knowing what is next
and getting into it without hunting through an invite. That works on any calendar EventKit can
see — Lark, Google, Exchange, iCloud — because the meeting link is in the event, not the API.

## Requirements

1. Detect meeting links in calendar events. Cover Lark/Feishu, Tencent Meeting, DingTalk, Zoom,
   Google Meet, Microsoft Teams, and Webex.
2. Search the event's URL, location, and notes fields. Real invites put the link in any of them.
3. When the next event has a detected link, offer a Join control in the popover that opens it.
4. Show time remaining until the next event starts, and switch to an in-progress indication once
   it has started.
5. Make the countdown available in the menu bar as an opt-in, off by default. It must coexist
   with the existing clock carousel rather than replacing it.
6. Define "next event" explicitly: it must respect the user's existing calendar selection
   (`calendarSelectionMode`, `selectedCalendarIDs`) and skip all-day events.
7. Detection must not mangle links. If a URL is ambiguous, prefer showing nothing over opening
   the wrong thing.
8. Every new string exists in `en` and `zh-Hans`.

## Constraints

- Deployment floor is macOS 13.
- No new dependencies. Link detection is pattern matching over strings already fetched.
- No network access. Links are opened through the system, never fetched or resolved by the app.
- Event data continues to come from EventKit only. Nothing about this task adds a calendar
  provider.
- The countdown must not add a second timer. `StatusBarController` already ticks once per second
  (`StatusBarController.swift:251-259`).

## Acceptance Criteria

- [ ] An event carrying a Lark meeting link shows a Join control that opens the meeting.
- [ ] The same holds for Zoom, Google Meet, Teams, Tencent Meeting, DingTalk, and Webex.
- [ ] Links are found whether they sit in the URL, location, or notes field.
- [ ] An event with no meeting link shows no Join control and no error.
- [ ] The countdown reflects the next non-all-day event from the user's selected calendars.
- [ ] Once a meeting has started, the UI says so rather than counting to a past time.
- [ ] The menu bar countdown is off by default; enabling it does not displace the clock.
- [ ] Link detection has unit coverage with realistic invite bodies per provider, including at
      least one that must not match.
- [ ] `scripts/verify-localizations.swift` passes.
- [ ] `swift build` and `swift test` pass.

## Out of scope

- Lark Open API, OAuth, and any per-provider authentication.
- Launching native meeting clients by URL scheme rather than handing the link to the system.
- Meeting reminders or notifications. `AlertRuleEngine` is a separate surface.
- RSVP, attendee lists, or any event mutation.
