# Implementation Plan — Plain-language power and wake insight

Ordered so the tree builds and the app runs after every step. The first step is the one
that makes the feature work at all on this machine; everything after it is additive.

## Step 0 — Capture fixtures before changing anything

The current parser's behaviour is the baseline, and the pathological input only exists
on a live machine.

```bash
pmset -g log | grep "Wake Requests" | tail -20      > wake-requests.txt
pmset -g log | grep -E " (Sleep|Wake|DarkWake) "    > wake-events.txt
pmset -g assertions                                 > assertions.txt
ioreg -rn AppleSmartBattery                         > battery.txt
pmset -g log | head -50000                          > log-slice.txt
```

Scrub before committing: hostnames, usernames, the account-number segment of
`com.apple.dasd:501:…`, and any Wi-Fi SSID. Record the *real* uncompressed size
(23.9 MB) in a constant so the streaming test asserts against a realistic shape without
committing the file.

**Validate:** fixtures load in a test and contain the domains the design names.

---

## Step 1 — Stream the log instead of buffering it  ▸ R1

`LineStreamingCapture` alongside the existing `BoundedPipeCapture`: drains the pipe,
splits on newlines, applies a predicate per line, retains only what passes.

- `FixedCommandRunner` gains a streaming variant. The existing buffered call stays for
  the small commands.
- The wake reader passes a predicate matching only the domains it wants.
- Cap trips now produce a *partial* result carrying how far back it reached, not an
  error that empties the list.

**Validate:** on this Mac, the wake list is populated where it was empty. This is the
single acceptance criterion that made the feature useless.
**Rollback point:** self-contained; everything after builds on it.

---

## Step 2 — Separate what was scheduled from what happened  ▸ R2

- `ScheduledWake` as its own type. The `Wake Requests` parser produces only these.
- The `WakeEvent` regex is anchored so it can no longer match the `Wake Requests`
  domain — the defect becomes structurally impossible, not merely fixed.
- `WakeEvent.id` stops embedding the reason text.
- One-off migration: existing persisted records whose reason looks like a
  `[process=…]` blob are dropped on load, because they are the fabricated ones.

**Validate:** fixture test — a `Wake Requests` line yields zero `WakeEvent`s.
**Watch:** users have this history on disk already. Dropping records is deliberate and
must be stated in the UI as a one-time cleanup, not done silently.

---

## Step 3 — Attribute wakes  ▸ R2

- Correlate a `DarkWake`/`Wake` to the `*` `ScheduledWake` whose `wakeAt` is within
  tolerance.
- Interrupt-token table as data, with an explicit unknown case.
- `WakeCause` replaces the free-text reason.

**Validate:** at least one real wake on this Mac attributes to a named process. A wake
outside tolerance stays `.unattributed` rather than being guessed.

---

## Step 4 — What is keeping the Mac awake  ▸ R3

- `pmset -g assertions` parser: `pid <n>(<name>): [<id>] <HH:MM:SS> <Type> named: "<reason>"`
  plus indented continuations, preferring `Localized=` for display.
- Mark MenuCue's own `caffeinate` as self-inflicted.

**Validate:** run `caffeinate -d` and confirm it is named. Toggle MenuCue's own Keep
Awake and confirm it is attributed to MenuCue. On this Mac, `UURemote` at 89 hours
should appear immediately.

---

## Step 5 — Continuous monitoring  ▸ R4

- Cadences per `design.md §5`, gated on a persisted "user has opened this once"
  preference, honouring adaptive sampling.
- Process energy accumulates into a bounded per-process history.

**Validate:** close the popover, wait, reopen — history covers the closed period.
Measure idle CPU before and after enabling and record both numbers.
**Review gate:** if idle cost is not negligible, stop and reconsider the cadence rather
than shipping a background sampler that drains the battery.

---

## Step 6 — Storage corrections  ▸ R4

Incremental rewrite, honest version stamping with migration, `clearedAt` suppressing
display without blocking backfill, time zone captured per record.

**Validate:** relaunch across a real sleep/wake cycle with the app closed; history is
continuous. Change the system time zone; historical daily buckets do not move.

---

## Step 7 — The pane  ▸ R5

Answer-first layout per `design.md §7`. Every count carries its window. Unavailable
readings use `UnsupportedNote`. All strings in both catalogs.

**Validate:** render in light and dark via `ImageRenderer` and look at the result —
the technique that caught the undersized typography on the Dashboard. Then open it in
the running app.

---

## Step 8 — Carried fixes  ▸ audit items 4–7

Voltage key scoping, negative-amperage regex, refresh feedback, since-boot labelling.
The existing test asserting the silent-throttle behaviour is updated with a note on why
it changed.

**Validate:** fixture tests for the nested-then-top-level `Voltage` ordering and for a
negative amperage.

---

## Step 9 — Quality pass

1. `swift build` — no new warnings.
2. `swift test` — green.
3. `swift scripts/verify-localizations.swift` — and the code→catalog scan that caught
   the six dead translations, since this step adds many strings.
4. Walk the pane in the running app against `pmset -g log` output read by hand.
5. Re-read acceptance criteria one by one.
6. Dispatch `trellis-check` for full-scope review.

---

## Rollback points

| After step | Reverting gives back |
|---|---|
| 1 | The empty wake list — but nothing else is lost |
| 2 | Fabricated wakes reappear; persisted history already cleaned |
| 5 | Foreground-only sampling |

Steps 1–4 are additive to the parser layer. Step 2's history cleanup is the only
destructive action and is one-way.

## Validation commands

```bash
swift build && swift test
swift scripts/verify-localizations.swift Sources/MenuCue/Resources/{en,zh-Hans}.lproj/Localizable.strings
pmset -g assertions                       # ground truth for step 4
pmset -g log | grep -c "Wake Requests"    # ground truth for step 2
```
