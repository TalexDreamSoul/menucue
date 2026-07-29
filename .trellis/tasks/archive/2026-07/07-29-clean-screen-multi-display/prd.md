# Adapt Clean Screen to multiple displays

## Goal

Ensure Clean Screen reliably covers every connected display for the whole cleaning session, including when the display topology changes while the mode is active.

## Background

- `CleaningModeController.start(mode:)` currently snapshots `NSScreen.screens` and creates one borderless screen-saver-level window per display (`Sources/MenuCue/QuickActionService.swift`).
- The controller does not observe display-parameter changes, so displays connected after startup are left uncovered and stale windows can remain after a display is disconnected or rearranged.
- Existing tests only verify the five-minute duration and do not exercise the display-to-window mapping.

## Requirements

- When Clean Screen starts, every connected display is covered by exactly one borderless black overlay sized to that display.
- While Clean Screen remains active, connecting, disconnecting, rearranging, or changing the resolution of a display refreshes the overlay set to match the current display topology.
- Refreshing display overlays must not reset the countdown, reinstall input monitors, or emit a false cleaning-mode state transition.
- Exiting or timing out Clean Screen closes every overlay and removes any display-change observer.
- Clean Keyboard must retain its existing behavior; this task must not broaden keyboard-blocking permissions or event interception.
- Every display overlay shows the title, shared countdown, and exit button; exiting from any overlay ends the single cleaning session.

## Acceptance Criteria

- [x] Starting Clean Screen with two or more displays creates exactly one correctly framed overlay per display.
- [x] Every display shows the same cleaning title, shared countdown, and working exit button.
- [x] A display topology change during Clean Screen reconciles added, removed, and resized displays without restarting the session countdown.
- [x] Stopping Clean Screen removes all overlays and the display-change observer.
- [x] Existing single-display, timeout, Escape-hold, and Clean Keyboard behavior remains unchanged.
- [x] Automated tests cover initial multi-display mapping, topology reconciliation, and cleanup without requiring physical displays.
- [x] The relevant test suite and project build pass.

## Out of Scope

- Remembering display-specific cleaning preferences.
- Changing the five-minute cleaning duration.
- Redesigning the cleaning overlay visual style.
