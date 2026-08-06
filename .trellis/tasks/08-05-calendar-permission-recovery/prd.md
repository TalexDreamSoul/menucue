# Calendar permission recovery flow

Parent: `08-05-menubar-ux-system-control`

## Goal

Make calendar permission recoverable from inside the app. Today, if macOS declines to show
the TCC prompt, "Grant Calendar Access" appears to do nothing and the user is left with no
next step.

## Background

macOS prompts once per app per service. After a prompt has been raised and dropped,
`requestFullAccessToEvents` returns immediately with `granted=false, error=nil` while the
authorization status stays `notDetermined`.

`AppModel.requestCalendarAccess()` (`AppModel.swift:424-433`) reads that as success: `error`
is nil, so `errorMessage` is cleared and the UI is identical to before the click. The button
looks broken. Neither the popover banner (`StatusPopoverView.swift:270-285`) nor the settings
pane (`StatusPopoverView.swift:1392-1399`) offers a route to System Settings for `.denied`
either.

This was reproduced on the developer's machine on 2026-08-05; see the parent's `notes.md`.
The environment was repaired, but the app-side gap is real and will hit any user whose prompt
is suppressed or who denies once and changes their mind.

A second contributor was found on 2026-08-05 while rebuilding: `scripts/build-app.sh` defaults
to `CODESIGN_IDENTITY="-"`, i.e. ad-hoc. TCC keys an ad-hoc bundle on its cdhash, which changes
on **every** rebuild, so each local build is a new app to TCC and drops any calendar grant. This
is a development-loop hazard, not a shipping defect — releases sign with Developer ID. It is
recorded here because it will otherwise be rediscovered as "the permission keeps resetting".

## Requirements

1. Detect the "requested but still `notDetermined`" outcome and surface it as a distinct
   state, separate from "not asked yet".
2. In that state, and in `.denied` and `.restricted`, offer a control that opens
   System Settings directly at Privacy & Security → Calendars.
3. Explain what to do there, in one sentence. The user needs to know they are toggling
   MenuCue on in a list, not hunting for a dialog.
4. Re-check authorization when the app becomes active again, so returning from System
   Settings updates the UI without a manual Refresh.
5. Apply the same treatment in both places that currently show the permission state: the
   popover banner and the settings pane.
6. `writeOnly` keeps offering the plain request, since escalation to full access can still
   prompt.
7. Every new string exists in `en` and `zh-Hans`.

## Constraints

- Deployment floor is macOS 13. The settings deep link and the full-access API both need
  version-appropriate handling; the project already has a pattern for the former at
  `LanguageRegionSettingsView.swift:113`.
- Do not add a Full Disk Access requirement or read the TCC database. Detection must come
  from `EKEventStore` return values only.
- No polling loop for authorization state.

## Acceptance Criteria

- [ ] Clicking Grant when macOS suppresses the prompt produces visible, actionable feedback
      rather than nothing.
- [ ] The System Settings control opens Privacy & Security → Calendars.
- [ ] Toggling MenuCue on in System Settings and returning to the app updates the state with
      no manual Refresh.
- [ ] A first-run user who has never been asked still gets the ordinary system prompt on the
      first click, with no extra step in front of it.
- [ ] `.denied` shows the settings route; `.fullAccess` shows neither the banner nor the button.
- [ ] `scripts/verify-localizations.swift` passes.
- [ ] `swift build` and `swift test` pass.

## Out of scope

- Lark / Feishu calendar integration. Deferred at the parent level; users subscribe the Lark
  ICS link into macOS Calendar and EventKit picks it up unchanged.
- Any change to how events are queried or displayed once access is granted.
