# Status clock push transition

Parent: `08-05-menubar-ux-system-control`

## Goal

Restore directional motion when the menu bar clock carousel switches clocks, and stop that
motion from being priced at the cost of the highest animation tier.

## Background

Scrolling over the status item switches clocks. The switch currently cross-fades, which
discards the direction the user scrolled — even though direction is already computed
(`ClockCarouselScrollIntent`) and passed down as `ClockTransitionOrigin`.

`MotionPreferences.swift:81-88` only returns `.push` for `.full`. `.full` also turns on 20fps
continuous popover redraw, so a user who wants a directional clock switch has to accept an
unrelated rendering cost. See the parent's `notes.md` for the full diagnosis.

## Requirements

1. `.elegant` — the default tier — uses a vertical push in the scroll direction.
2. `.minimal` and macOS Reduce Motion keep the current instant swap. This is unchanged
   behaviour and must not regress.
3. The push must clip to the status item's bounds. It must never draw over neighbouring
   menu bar items.
4. Push duration must not exceed the scroll cooldown, so consecutive scrolls do not queue
   transitions faster than they complete.
5. Direction: scrolling toward the next clock moves the outgoing title in the direction the
   user scrolled. Respect `isDirectionInvertedFromDevice`, which the existing intent already
   resolves.
6. No new user-facing setting. This is a correction to how existing tiers behave.

## Constraints

- Menu bar rendering runs on every `refreshClockTitle`, called once per second by the timer
  (`StatusBarController.swift:251-259`). The transition must only be added when the clock
  identity actually changes, as it is today.
- Reduce Motion is read from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
  and must keep short-circuiting before any transition is built.

## Acceptance Criteria

- [ ] With default settings, scrolling over the status item moves the clock vertically in the
      scroll direction instead of fading.
- [ ] Scrolling the other way moves it the other way.
- [ ] Nothing is drawn outside the status item during the transition, verified against a
      neighbouring menu bar icon.
- [ ] With Reduce Motion enabled, or quality set to `.minimal`, the title swaps with no
      animation.
- [ ] Scrolling rapidly through a multi-clock list produces no visible pile-up or dropped
      titles.
- [ ] Unit coverage for the quality-to-motion mapping is updated to match the new table.
- [ ] `swift build` and `swift test` pass.

## Out of scope

- Any change to what `.full` enables beyond clock motion.
- Reworking `continuousFrameInterval` or the rest of the animation quality model. That is
  `08-02-animation-quality-performance`.
