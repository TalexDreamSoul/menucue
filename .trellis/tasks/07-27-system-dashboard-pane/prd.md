# System Dashboard pane with per-metric tabs

## Goal

Give MenuCue a real system-monitoring surface. The menu-bar popover stays a glanceable
summary; every metric card in it becomes a doorway into a full Dashboard pane inside the
Settings window, where each subsystem gets a tab with depth the 360pt popover cannot carry.

Also trim the popover's memory hover panel back to a glance: three processes, not six.

## Requirements

### R1 — Memory hover panel shows the top three processes

- The popover's memory detail panel lists at most 3 processes.
- The Dashboard's Memory tab still shows a longer list, so the process limit must be a
  per-consumer choice rather than a single global constant.

### R2 — Metric cards are clickable deep links

- Clicking the CPU, Memory, Disk, Fan, or Network card in the popover opens the Settings
  window on the Dashboard pane, pre-selected to that card's tab.
- Hover detail keeps working exactly as it does today; the click is additive.
- Cards read as clickable: press feedback, pointer affordance, and an accessibility hint.
- Deep-linking works repeatedly, including when the Settings window is already open.

### R3 — Dashboard pane in the Settings window

- The Settings sidebar gains a `Dashboard` entry, listed first.
- The Dashboard has a horizontal tab bar: **CPU, GPU, Memory, Storage, Network, Sensors**.
- Card → tab mapping: CPU→CPU, Memory→Memory, Disk→Storage, Network→Network, Fan→Sensors.
  GPU has no popover card and is reached from the tab bar.
- Tab content scrolls independently; the pane header and tab bar stay pinned.

### R4 — Tab content is professionally detailed

Every value must come from a real reading. No placeholder or synthesized numbers, and no
private/undocumented API beyond the SMC and HID paths the app already ships.

| Tab | Required content |
|---|---|
| CPU | Load area chart over time; user/system/idle split; per-core load bars; P/E cluster core counts; 1/5/15-minute load averages; per-cluster temperatures |
| GPU | Device utilization + history chart; renderer utilization; in-use graphics memory; GPU temperature |
| Memory | Used/total with pressure level; app / wired / compressed / cached breakdown; swap used + total; top processes with proportion bars |
| Storage | Every mounted volume with used/total/free and format; read + write rate history chart; read/write IOPS; bytes read/written since boot |
| Network | Download + upload rate history chart; primary interface, IPv4 and MAC; per-interface cumulative in/out bytes |
| Sensors | Every fan with current RPM, min/max range and RPM history; the full labelled temperature sensor list |

- A metric the current Mac cannot report (no fans, no GPU counters, no swap) shows an
  explicit "not reported" state rather than a zero.

### R5 — Cost stays proportional to what is visible

- The Dashboard samples only while it is on screen and stops on disappear.
- Expensive probes (process enumeration, volume enumeration, interface walk, IO registry)
  run only while the tab that needs them is selected.
- Opening the Settings window on any other pane must not start sampling.
- The Dashboard honors the existing adaptive sampling settings.

## Constraints

- macOS 14+, SwiftUI, Swift 5.9. No new package dependencies.
- **Every new user-visible string goes through `L10n.string("...")` with a static literal key,
  and is added to both `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`.**
  `scripts/verify-localizations.swift` and `LocalizationResourceTests` enforce this.
- Views do not touch `UserDefaults` directly; settings mutations go through `AppModel`.
- Existing popover behaviour, layout, and sampling cost must not regress.

> **Revised 2026-07-27, after the `origin/master` merge.** Upstream landed
> `9bbceb8 feat: add language and region controls`, which introduced the `L10n` system,
> `en`/`zh-Hans` `.strings` catalogs, and a verification script. Two earlier constraints are
> now void: "all user-visible strings in English" and "localization is out of scope". The
> brand name is embedded directly in `L10n` keys upstream (`L10n.string("MenuCue Settings")`)
> because a lookup key must be a static literal — so `ProductBrand.displayName` interpolation
> is **not** available inside localized strings.

## Acceptance Criteria

- [ ] Hovering the popover's Memory card lists exactly 3 processes on a machine with more.
- [ ] Clicking each of the five metric cards opens Settings → Dashboard on the mapped tab.
- [ ] Clicking a card twice in a row, and clicking a card while Settings is already open,
      both land on the correct tab.
- [ ] All six tabs render with live values on this Mac; every row in the R4 table is
      populated or shows an explicit unsupported state.
- [ ] Switching tabs starts the newly selected tab's probes and stops the previous tab's.
- [ ] Closing the Settings window or leaving the Dashboard pane stops all sampling.
- [ ] Opening Settings on Overview starts no timer (Overview still renders the cache).
- [ ] `swift build` and `swift test` pass; new pure logic (process ranking limit, per-core
      delta math, section↔target mapping, history ring buffer, pressure-level decoding)
      has unit coverage.
- [ ] Fanless Macs and Macs without GPU counters render the affected tabs without empty
      boxes or zeros presented as readings.
- [ ] Every new string is localized in both catalogs; `swift scripts/verify-localizations.swift`
      and `LocalizationResourceTests` pass.

## Out of scope

- CPU frequency readout — not available on Apple silicon without private APIs.
- A sortable full process table (the "Processes" tab option was declined).
- Persisting the last-selected Dashboard tab across launches.

## Prerequisite (blocking)

The `origin/master` merge must be resolved first — 30 conflicting files, including every file
this task edits. Resolution rule agreed with the user: **take upstream content, keep the
MenuCue identity**, and re-apply local-only functionality that upstream lacks (confirmed so
far: the popover keyboard tab navigation from task `07-27-popover-keyboard-tab-navigation`,
whose test `PopoverTabNavigationTests.swift` is not in conflict and will fail to compile if
dropped). Design line references in `design.md` must be re-verified against the merged tree,
since upstream's `SystemMetricsService` is a substantially different implementation
(cancellation token, dependency injection, serialized sampling, worker-confined baseline).
