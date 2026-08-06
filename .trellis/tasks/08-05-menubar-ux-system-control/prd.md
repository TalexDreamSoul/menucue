# Menu bar UX and system control follow-ups

## Goal

Close four independently shippable gaps found while reviewing MenuCue v0.6.10 against
comparable menu-bar products (Dato, Itsycal, Stats, iStat Menus, Macs Fan Control):
the status clock switch lost its directional motion, calendar permission has no recovery
path when macOS suppresses the TCC prompt, fans are read-only, and there is no meeting
entry point.

This parent owns the shared requirement set and the cross-child acceptance criteria.
It has no direct implementation work of its own.

## Task map

| Child | Deliverable | Independent? |
|---|---|---|
| `08-05-status-clock-push-transition` | Status clock switches with vertical push, clipped to the status item | Yes |
| `08-05-calendar-permission-recovery` | Permission UI recovers when the TCC prompt never appears | Yes |
| `08-05-fan-control-spike` | Verify whether Apple silicon accepts SMC fan writes; decide go/no-go | Yes — gates any fan feature |
| `08-05-meeting-join-countdown` | Detect meeting links in events, offer one-click join | Yes |

Ordering: none of the four block each other. `fan-control-spike` is a decision gate for
future fan work, not a prerequisite for the other three.

## Source requirements

Raised by the developer on 2026-08-05:

1. The status bar clock carousel fades between clocks instead of moving vertically.
2. Clicking "Grant Calendar Access" does nothing; evaluate Lark (Feishu) calendar support.
3. Let users adjust fan speed.
4. Review the product overall against comparable tools and propose adjustments.

## Constraints

- macOS 13 Ventura is the deployment floor (`Package.swift`). Anything newer needs a fallback.
- The app ships notarized with hardened runtime; privileged work must go through the
  existing `MenuCueHelper` LaunchDaemon, not through added entitlements.
- Localization covers `en` and `zh-Hans` only. Every user-visible string added must exist
  in both, and `scripts/verify-localizations.swift` must pass.
- No new third-party dependencies.

## Cross-child acceptance criteria

- [ ] `swift build` and `swift test` pass with all four children merged.
- [ ] `scripts/verify-localizations.swift` reports no missing keys.
- [ ] No child regresses the popover frame budget measured in `08-02-animation-quality-performance`.
- [ ] Each child's own acceptance criteria are met and verifiable without the others.

## Out of scope

- Lark Open API integration. Evaluated and deferred: a distributed desktop app cannot embed
  `app_secret`, so a first-party OAuth path needs either PKCE support or a relay service —
  a whole subsystem for data the user can already surface by subscribing the Lark calendar's
  ICS link into macOS Calendar, where EventKit picks it up with no code change. The user
  value behind the request ("what is my next meeting, let me join it") is delivered by
  `08-05-meeting-join-countdown` instead, at a fraction of the cost.
- Menu bar monitoring widgets (CPU/RAM/network rendered in the status bar). This is the
  largest gap against Stats/iStat Menus, but it is a product-line decision, not a follow-up.
- Global hotkey to open the popover, battery charge limiting, Focus-mode awareness,
  splitting `StatusPopoverView.swift` (2478 lines), and replacing the `top`/`pmset`
  subprocess sampling in `ProcessEnergyService`. All are recorded in `notes.md` as a backlog.

## Notes

- Diagnosis work already done on 2026-08-05 is recorded in `notes.md`, including the
  LaunchServices/TCC cleanup that was applied to the developer's machine.
