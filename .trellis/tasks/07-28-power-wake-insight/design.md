# Design — Plain-language power and wake insight

## 1. Data sources, chosen against real output

Every format below was captured from this Mac, not assumed.

| Need | Source | Why |
|---|---|---|
| Currently preventing sleep | `pmset -g assertions` | Small, current, and already carries human text |
| Who scheduled a wake | `pmset -g log`, `Wake Requests` domain | The only place a *process* is named |
| Wakes that happened | `pmset -g log`, `Sleep`/`Wake`/`DarkWake` domains | As today, but correctly filtered |
| Per-process energy | `top -l 2 -stats pid,command,power` | Unchanged; a proxy, labelled as one |
| Battery flow | `ioreg -rn AppleSmartBattery` | Unchanged, with the key-scoping bug fixed |

### `pmset -g assertions` — the source the feature was missing

```
Listed by owning process:
   pid 49842(caffeinate): [0x0004a3ff...] 00:01:29 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
	Details: caffeinate asserting for 300 secs
	Localized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
   pid 832(UURemote): [0x00000045...] 89:44:59 PreventUserIdleSystemSleep named: "UURemote Disable Idle System Sleep"
```

Grammar: `pid <n>(<name>): [<id>] <HH:MM:SS> <AssertionType> named: "<reason>"`, followed
by optional indented continuation lines, of which `Localized=` is display-ready text.

This answers R3 directly and costs a few KB, so it needs none of the streaming
machinery below. Note the duration field: on this Mac `UURemote` has held
`PreventUserIdleSystemSleep` for 89 hours — exactly the kind of fact the pane exists
to surface.

### `Wake Requests` — the only process attribution available

```
2026-07-27 17:51:13 -0700 Wake Requests	[process=mDNSResponder request=Maintenance deltaSecs=7198 wakeAt=2026-07-27 19:51:11 info="upkeep wake"] [*process=dasd request=SleepService deltaSecs=946 wakeAt=2026-07-27 18:06:58 info="com.apple.dasd:501:com.apple.chronod.nextScheduledTimelineRefresh"] …
```

- One line holds *many* bracketed requests.
- `*` marks the request that will fire first — the one that will actually wake the Mac.
- Logged **at sleep time**, describing the **future**. This is why the current regex
  showing them as wakes that occurred is wrong, not merely mislabelled.

## 2. Reading the log without choking

The blocker is `BoundedPipeCapture` accumulating all 23.9 MB against a 16 MB cap.

**Rejected:** raising the cap. The output grows with uptime; the next machine hits it
again.

**Rejected:** `sh -c "pmset -g log | grep -v Assertions"`. It fixes the size but adds a
shell to the trust boundary for no benefit over doing the same filtering in-process.

**Chosen:** a line-oriented streaming reader. `LineStreamingCapture` drains the pipe
continuously, splits on newlines, offers each line to a predicate, and keeps only what
the predicate accepts. Peak memory is one line plus what is kept — for this Mac, 260 KB
of the 23.9 MB. The existing cap stays as a backstop against a single pathological line
and, if it does trip, the result is marked partial and the pane says how far back it
reached, rather than showing nothing.

Incremental refresh: the store records the newest timestamp it holds and the reader
stops once it reaches older lines, so a refresh after the first is bounded by what has
happened since.

## 3. Correlating a wake to the process that caused it

```
sleep at T0
  Wake Requests logged at T0 → [*process=dasd … wakeAt=T1]
DarkWake at T1' where |T1' − T1| ≤ tolerance
  ⇒ attributed to dasd, reason from info=
```

- Tolerance is a small window (seconds), because the scheduler is not exact.
- Only the `*` request is a candidate; the others were not going to fire first.
- No match within tolerance ⇒ fall back to the interrupt token, mapped to plain
  language, and the wake is marked `.unattributed` rather than guessed at.
- A `Wake Requests` line **never** becomes a `WakeEvent` on its own. It is a separate
  `ScheduledWake` type, which is what makes the fabrication defect structurally
  impossible rather than merely fixed.

### Interrupt tokens → plain language

A lookup with an explicit unknown case:

| Token contains | Plain language |
|---|---|
| `rtc`, `SleepService` | a scheduled background task |
| `HID`, `Multitouch`, `keyboard` | you (keyboard, trackpad or mouse) |
| `lid` | opening the lid |
| `wifibt`, `bluetooth` | a Bluetooth device or the network |
| `EC.` , `PMU` | the power controller |
| unmatched | shows the raw token, prefixed "woken by" |

The table is data, not a `switch`, so it is testable in isolation and a miss is
visible rather than silently collapsing to a generic string.

## 4. Model

```swift
struct WakeEvent {          // something that happened
  let at: Date
  let kind: WakeKind        // .sleep, .darkWake, .userWake
  let cause: WakeCause
  let durationSeconds: Int?
  let batteryPercent: Int?  // both currently stripped by the parser
}

enum WakeCause {
  case process(name: String, pid: Int32?, request: String, detail: String?)
  case interrupt(token: String, plain: String)
  case unknown
}

struct ScheduledWake {      // something that was planned — never rendered as a wake
  let loggedAt: Date
  let wakeAt: Date
  let process: String
  let request: String
  let info: String?
  let isWinning: Bool
}

struct SleepAssertion {     // something holding the Mac awake right now
  let pid: Int32
  let process: String
  let type: String          // PreventUserIdleSystemSleep, …
  let reason: String
  let localized: String?
  let heldSeconds: Int
  var isSelf: Bool          // MenuCue's own caffeinate
}
```

`WakeEvent.id` stops embedding the reason string — it becomes timestamp + kind, so a
parser change cannot orphan persisted history.

## 5. Continuous monitoring

Two cadences, both honouring the existing adaptive sampling settings:

| What | When | Cost |
|---|---|---|
| Wake backfill | on `didWakeNotification`, and every 15 min while enabled | incremental parse, KB |
| Assertions | every 60 s while enabled | `pmset -g assertions`, a few KB |
| Process energy | every 60 s while enabled, rolled into a bounded history | one `top -l 2` |

- Nothing runs until the user has opened the Power pane once; the preference then
  persists. This satisfies "does not sample before asked" without making the feature
  useless when the popover is closed.
- Process energy accumulates into a ring of per-process running totals, so "what kept
  running" is answerable for a past window rather than being a one-second peek.

## 6. Storage

`WakeHistoryStore` keeps its location and retention, with three corrections:

1. Rewrite only what changed. Decoding and re-encoding the whole file on every refresh
   does not survive the record counts the current bugs produce.
2. Version stamping made honest — the writer stamps what the reader accepts, with a
   migration step rather than reinterpreting a v1 file as v2.
3. `clearedAt` no longer permanently blocks older re-ingestion; it suppresses display
   without preventing backfill of a window the app genuinely missed.

Daily bucketing moves to a fixed time zone captured with the record, so historical
buckets do not re-shuffle when the user travels.

## 7. Presentation

The pane leads with the answer:

```
┌─────────────────────────────────────────────┐
│ Your Mac last woke at 05:20                 │
│ dasd asked for it, to check for accessory   │
│ updates.                                    │
├─────────────────────────────────────────────┤
│ Keeping your Mac awake right now            │
│  • UURemote — for 89 hours                  │
│  • caffeinate — MenuCue's Keep Awake        │
└─────────────────────────────────────────────┘
```

- Sentences at readable size, raw tokens demoted to secondary detail.
- Every count carries its window: "since you last restarted", "in the last 30 days",
  "today".
- Unavailable readings use the existing `UnsupportedNote` idiom, so a `0` never stands
  in for unknown.
- Wake causes are localized: the plain-language table is `L10n` keys, and the raw token
  is shown verbatim in both languages because it is an identifier, not prose.

## 8. Fixes carried along

| Defect | Fix |
|---|---|
| Voltage read from nested `BatteryData` | Scope the match to the top-level dictionary rather than `firstMatch` over flat text |
| Sign-flip risk | Accept an optional leading `-`; test with a negative fixture |
| Refresh silently throttled | Set `isRefreshing` before the throttle check, or drop the throttle when the press is user-initiated. The existing test asserting the current behaviour is updated, and why is recorded |
| Since-boot stats unlabelled | Each figure carries its window |

## 9. Test strategy

Parsers are pure functions over captured text. Fixtures committed under
`Tests/MenuCueTests/Fixtures/`, scrubbed of hostnames, account identifiers and the
account-number segment of `com.apple.dasd:501:…`.

- `Wake Requests` line with several bracketed requests, one starred → yields
  `ScheduledWake`s only, never a `WakeEvent`.
- Real `DarkWake` lines → cause is the interrupt token, mapped.
- A sleep/wake pair around a scheduled wake → attributed to the named process.
- The same pair with the wake far outside tolerance → `.unattributed`, not guessed.
- `pmset -g assertions` with continuation lines, two assertions from one process, and
  a process holding several types.
- A slice shaped like this Mac's 23.9 MB output → the streaming reader keeps only the
  matching lines and never allocates the whole input. Asserted on peak retained size,
  not on wall-clock.
- `ioreg` fixtures with the nested-then-top-level `Voltage` ordering, and with a
  negative amperage.
