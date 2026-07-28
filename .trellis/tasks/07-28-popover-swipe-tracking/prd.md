# Fix popover trackpad swipe navigation

## Goal

A two-finger sideways flick over the popover changes tab. Reported broken three times;
this task is not done until it is observed working on a real trackpad.

## What is already known

Measured on this Mac, not assumed:

| Fact | Value |
|---|---|
| `AppleEnableSwipeNavigateWithScrolls` | `1` — two-finger sideways is "swipe between pages" |
| `TrackpadThreeFingerHorizSwipeGesture` | `0` |
| `NSEvent.isSwipeTrackingFromScrollEventsEnabled` | `true` |
| Accessibility permission needed? | **No.** The app reads no other process's UI; the earlier suspicion was wrong. `AXIsProcessTrusted()` is irrelevant to receiving one's own scroll events. |

Three implementations have been tried:

1. **Local event monitor** (`NSEvent.addLocalMonitorForEvents`) — never observed firing.
2. **`wantsForwardedScrollEvents(for:)`** — wrong API family. It forwards scroll events
   an inner scroll view *could not use*, for nested scrolling. It never sees a swipe.
3. **`wantsScrollEventsForSwipeTracking(on:)` + `NSEvent.trackSwipeEvent`** — the
   correct API for page swiping, currently shipped, **still unverified**.

The recognizer logic itself is not in doubt: `SwipeRecognizer` is a pure value type
with 10 passing tests, including that a vertical scroll with sideways drift is never
swallowed and that one gesture moves exactly one tab.

## Requirements

- A two-finger sideways flick over the popover moves one tab, in the direction of the
  flick, with the existing slide animation.
- Vertical scrolling inside the popover is untouched.
- One gesture moves exactly one tab; inertia does not move a second.
- Works with page swiping both enabled and disabled in the trackpad pane.
- Mouse-wheel horizontal and the arrow keys keep working.

## Verification requirement

This is the crux, and the reason the task exists. Prior attempts failed because the
fix was reasoned about but never observed.

- [ ] **A real trackpad gesture is observed changing the tab.** Not a unit test, not a
      synthetic `CGEvent`, not a code reading.

Synthetic events were attempted and did not reach the popover even with the posting
process trusted for accessibility, so that route is closed. Verification therefore
needs either a human gesture with `MENUCUE_SWIPE_LOG=1`, or a working automated UI
harness — establishing one is in scope.

## Acceptance criteria

- [ ] Log with `MENUCUE_SWIPE_LOG=1` shows the container receiving the gesture.
- [ ] The tab changes, once, in the right direction.
- [ ] Vertical scrolling still scrolls.
- [ ] Turning page swiping off in System Settings still leaves the gesture working
      through the accumulator path.
- [ ] `swift test` green.

## Diagnostic decision tree

Once a log exists, the next step is already decided:

| Log shows | Conclusion | Next |
|---|---|---|
| no lines at all | events never reach the container | the scroll view consumes them first; wrap differently or intercept at the window |
| lines, `phase=1` then nothing | `trackSwipeEvent` not engaging | check the horizontal-dominance guard and the `.lockDirection` option |
| lines, `accumulator -> pass` | judged as vertical | lower `dominance` |
| lines, `accumulator -> consume` only | never reaches the threshold | lower `threshold` from 28 |
| `navigate` logged, tab unchanged | the relay or the SwiftUI binding is the fault, not the gesture |
