# Diagnosis notes — 2026-08-05

Findings that produced this task tree. Kept out of `prd.md` because they are evidence,
not requirements.

## 1. Status clock fades instead of pushing

Not a regression — a default-tier binding.

`Sources/MenuCue/MotionPreferences.swift:81-88` maps animation quality to clock motion:

```swift
case .full:    return .push
case .elegant: return .fade   // default, AppModels.swift:170
case .minimal: return .none
```

The transition itself is applied in `StatusBarController.swift:328-342`.

Two problems with the binding:

- A status clock switch is **one** `CATransition` per user scroll. Gating it behind `.full`
  makes the user also opt into `continuousFrameInterval = 1/20` (20fps continuous popover
  redraw, `MotionPreferences.swift:72-79`) to get it. Cheap animation, expensive toll.
- Fade discards direction. The interaction is a carousel; the scroll direction is already
  computed and threaded through as `ClockTransitionOrigin` (`StatusBarController.swift:332`),
  then thrown away in the fade branch.

Likely reason push was abandoned: `configureStatusItem` (`StatusBarController.swift:105-127`)
sets `button.wantsLayer = true` but never `layer.masksToBounds = true`. AppKit layers do not
clip by default, so a push renders the outgoing title sliding **outside** the status item and
over neighbouring menu bar icons.

Also note `transition.duration = 0.34` against a `wheelSwitchCooldown` of `0.16`
(`StatusBarController.swift:78`) — fast scrolling queues transitions faster than they finish.

## 2. "Grant Calendar Access" does nothing

Ruled out by inspection:

- `NSCalendarsFullAccessUsageDescription` and `NSCalendarsUsageDescription` are both present
  in the built `Info.plist` (generated at `scripts/build-app.sh:160-163`).
- Both installed copies are Developer ID signed by `ZiXian Tang (2L5YC85FQ7)`, hardened runtime.
- The running process has PPID 1 (launchd), so the TCC responsible process is not a shell.
- The call path is intact: `StatusPopoverView.swift:1396` → `AppModel.requestCalendarAccess()`
  (`AppModel.swift:424`) → `CalendarService.requestAccess()` (`CalendarService.swift:33`).

Actual cause — TCC client ambiguity plus macOS's prompt-once rule. `lsregister` held **11**
registrations for `com.tagzxia.app.menucue`, 8 of them pointing at deleted build/verify
directories under `/private/tmp` and `/private/var/folders`. `tccutil reset Calendar
com.tagzxia.app.menucue` then printed its success line **three times**, confirming tccd was
holding three separate client records for one bundle id.

macOS prompts once per app per service. Once a prompt is raised and dropped, later
`requestAccess` calls return immediately with `granted=false, error=nil` while the status
stays `notDetermined` — which is exactly the reported symptom, and exactly the state the
current UI cannot distinguish from "not asked yet".

### Applied to the developer's machine on 2026-08-05

- Unregistered the 8 dangling LaunchServices paths with `lsregister -u` (targeted; the
  database was not rebuilt with `-kill`).
- `tccutil reset Calendar com.tagzxia.app.menucue`.
- Restarted MenuCue.

Three registrations remain and are all live: `/Applications/MenuCue.app`,
`.build/app/MenuCue.app`, and a `MenuCueProvisioning.app` in Xcode DerivedData. The first two
share a bundle id by design (release vs. local build) and will keep producing duplicate TCC
records on this machine. That is a dev-environment quirk, not a shipping defect.

### Gap that survives the cleanup

`AppModel.swift:424-433` treats "request returned, still `notDetermined`" as success — it
clears `errorMessage` when `error` is nil and shows no further affordance. Neither the popover
banner (`StatusPopoverView.swift:270-285`) nor the settings pane (`StatusPopoverView.swift:1392-1399`)
offers a System Settings link for `.denied`. The project already has the deep-link pattern at
`LanguageRegionSettingsView.swift:113`.

## 3. Fan control

`SystemSensorReader.swift` already contains a working `AppleSMC` client, but it is read-only:
`commandReadBytes = 5`, `commandReadKeyInfo = 9` (`SystemSensorReader.swift:218-220`). It reads
`FNum`, `F{n}Ac`, `F{n}Mn`, `F{n}Mx` (`SystemSensorReader.swift:29-43`).

Writing needs `SMC_CMD_WRITE_BYTES = 6` against:

- `F{n}Md` — `ui8`, fan mode, 0 = auto / 1 = forced
- `F{n}Tg` — `fpe2`, target RPM, encoded big-endian as `rpm * 4`

SMC writes require root, so this belongs in `MenuCueHelper`, which already runs as a
LaunchDaemon with XPC client signature validation (`Sources/MenuCueHelper/main.swift:510`).

Unverified premise: SMC write ACLs differ across Apple silicon generations. The target machine
is **Mac16,7 / Apple M4 Pro / macOS 26.5**. Whether M4 accepts `F0Md`/`F0Tg` writes at all must
be proven before any feature work — hence the spike child.

Safety requirements for any eventual feature: clamp targets to `[F{n}Mn, F{n}Mx]`, never allow
a floor below Apple's own curve, and restore `F{n}Md = 0` on app quit, on helper
`prepareForRemoval`, and from a helper-side heartbeat watchdog. A crash that leaves fans forced
low is a thermal hazard.

## 4. Product comparison backlog

Not scheduled. Recorded so it is not rediscovered.

MenuCue currently competes with Dato/Itsycal (clock + calendar) and Stats/iStat Menus
(monitoring) simultaneously, without leading either.

High value:

1. **No menu bar monitoring widgets.** Every metric lives inside the popover; the status bar
   shows only the clock. Stats' entire value proposition is CPU/RAM/network resident in the
   menu bar. This is the entry ticket for the monitoring product line.
2. **No meeting join / next-event countdown.** Dato's headline feature. Scheduled as
   `08-05-meeting-join-countdown`.
3. **No global hotkey** to open the popover. Every comparable tool has one.

Medium:

4. Battery health and charge limiting (AlDente territory); `PowerDiagnostics` is already the
   foundation.
5. Focus / Do Not Disturb awareness — suppress alerts during meetings.
6. Localization is `en` + `zh-Hans` only.

Engineering debt:

7. `StatusPopoverView.swift` is 2478 lines and should split along tab boundaries.
8. `ProcessEnergyService` samples via `top` at roughly a second of CPU per sample, and
   `PowerDiagnosticsService` spawns `pmset`. Both run in the background. For an app whose
   pitch includes saving energy, `libproc` / `IOReport` direct reads would be more defensible.
