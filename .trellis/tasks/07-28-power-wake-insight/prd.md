# Plain-language power and wake insight

## Goal

Answer two questions in words a person can act on:

- **"What woke my Mac?"** — a named process and why, not an interrupt code.
- **"What keeps running?"** — what has been holding the machine awake or burning
  energy over time, not a one-second peek.

## Why this is a rewrite, not a bug fix

The shipped feature is a faithful renderer of `pmset` strings. Audited on this Mac:

### The blocker

`PowerDiagnosticsProbe.swift:68` caps command output at 16 MB. Measured here:

```
pmset -g log            = 23.9 MB   (105,801 lines)
app's cap               = 16 MB
```

Over the cap the app kills `pmset` and throws `outputTooLarge`, so the wake list is
**permanently empty** and the pane shows a 9pt red "pmset returned too much data."
This is the reported problem. **98.6% of that output is `Assertions` lines the app
does not use** — `pmset -g log | grep -v Assertions` is 260 KB.

### The data the user wants is already in that output, and is discarded

The parser keeps only the text after `due to `, which is an interrupt source:

```
DarkWake … due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty
```

Two other domains in the same command carry exactly what was asked for:

```
Wake Requests: [*process=dasd request=SleepService wakeAt=… info="…deviceIdleCheck"]
                ↑ who scheduled the wake

Assertions:    PID 8064(bun) PreventUserIdleSystemSleep "agent session" 103:23:00
               PID 35353(Orca) NoDisplaySleepAssertion "Electron"
                ↑ who is preventing sleep
```

Neither is parsed. There is no assertion detection at all — the app cannot even report
the `caffeinate` it starts itself (`QuickActionService.swift:271`).

### Other confirmed defects

| # | Defect | Evidence |
|---|---|---|
| 1 | ~30% of shown wakes are fabricated | `(Sleep\|DarkWake\|Wake)\s+` also matches the `Wake Requests` domain — 40 of 133 matched lines. These are *future scheduled* wakes logged at sleep time, shown green and counted as real |
| 2 | Reason becomes a 500-char blob | Those lines have no `due to`, so `wakeReason` returns the whole line — and it is embedded in `WakeEvent.id` and persisted |
| 3 | Three time windows stacked unlabelled | `pmset -g stats` is since-boot (25/22/11) shown as bare integers, directly above "30-day local history" and "%d dark wakes today" |
| 4 | Wrong battery voltage key | `firstMatch` over flat `ioreg` text finds `"Voltage"=12348` nested inside `BatteryData` before the real top-level key |
| 5 | Sign-flip risk | The voltage regex accepts digits only; a negative literal would yield `+12.0 W` while discharging. Untested |
| 6 | "0" means "no data" | `?? 0` renders as "0 dark wakes today", indistinguishable from a true zero |
| 7 | Refresh is a silent no-op for 15s | Throttle returns before setting `isRefreshing`, so the button never even shows progress. A test asserts this behaviour |
| 8 | Reasons never localized | Card titles use `L10n`; `Text(event.reason)` prints the raw token |
| 9 | Full 23.9 MB re-parsed every refresh | Including 1s after every wake |

### What does not run in the background

- Wake data: only a `didWakeNotification` observer that refreshes a snapshot **nobody
  sees unless the popover is open**. No notification, no badge, no persisted signal.
- Process energy: driven purely by tab visibility, discarded on release. There is no
  history of "what kept running" — only a 1-second `top` sample, refreshed every 15s,
  so a daemon that wakes every 30s reads 0.0 essentially always.

## Requirements

### R1 — Read the log without choking on it

- Never buffer the full `pmset -g log`. Filter at the source so `Assertions` lines
  never enter the app's buffer.
- The cap stays as a backstop; exceeding it must degrade to a stated partial result,
  never to an empty list with a raw error string.
- Re-parsing must be incremental: only lines newer than what is already stored.

### R2 — Attribute wakes to a cause a person recognizes

- Parse `Wake Requests` and correlate each scheduled request to the wake it produced,
  using the `*` marker for the winning request.
- Render as a sentence: **"dasd woke your Mac at 05:20 to check for accessory
  updates."** Where only an interrupt source is known, say so plainly — "woken by the
  lid" / "woken by the network" — and keep the raw token available but secondary.
- Maintain a mapping from interrupt tokens to plain language, with an explicit
  fallback for unknown tokens that shows the token rather than inventing a cause.
- Never show a scheduled-but-not-yet-happened wake as a wake that occurred.

### R3 — Say what is keeping the Mac awake, now

- Parse the `Assertions` domain and `pmset -g assertions` for currently held
  assertions with the owning PID and its reason string.
- Show it as **"Orca is keeping your display awake."**, listing every holder.
- The app's own `caffeinate` must appear, attributed to MenuCue.

### R4 — Continuous monitoring

- Sampling continues while the popover is closed, at a low duty cycle that is stated
  in the UI and honours the existing adaptive sampling settings.
- Long-running and high-energy processes accumulate into a bounded history that
  survives relaunch, so "what kept running" can be answered for a past window.
- Nothing samples before the user has opened the feature at least once.

### R5 — A pane a person can read

- Lead with the answer, not the data: the most recent wake cause and anything
  currently preventing sleep, in a sentence, at readable size.
- Every number carries its window ("since boot", "last 30 days", "today").
- An unavailable reading says so; no `0` standing in for unknown.
- Every string localized in both catalogs, including wake causes.

## Acceptance criteria

- [ ] On this Mac — where `pmset -g log` is 23.9 MB — the wake list is populated. This
      is the specific regression that made the feature useless.
- [ ] No `Wake Requests` line appears as an occurred wake.
- [ ] At least one wake is attributed to a named process with a plain-language reason.
- [ ] With `caffeinate` running, the pane names it as preventing sleep; the same holds
      for MenuCue's own Keep Awake action.
- [ ] Every count on screen states its time window.
- [ ] Battery voltage matches the top-level `ioreg` key; a negative amperage renders as
      negative. Both covered by tests against captured fixtures.
- [ ] Refresh visibly does something every time it is pressed.
- [ ] History survives relaunch and a real sleep/wake cycle with the app closed, and is
      bounded with its size shown.
- [ ] Idle cost measured and stated.

## Constraints

- Parsers are tested against **captured real output** committed as fixtures, including
  this machine's pathological 23.9 MB shape (a representative slice, not the whole
  file) and the `Wake Requests` / `Assertions` domains.
- No new dependencies. No root beyond the existing privileged Helper.
- `pmset -g log` content is machine-specific; fixtures must be scrubbed of anything
  identifying before being committed.

## Out of scope

- `powermetrics`-grade per-process energy. It needs root and a sustained sampler; the
  `top` proxy stays, but is labelled honestly and sampled over a window rather than
  for one second.
- Changing power settings beyond what the Helper already exposes.
