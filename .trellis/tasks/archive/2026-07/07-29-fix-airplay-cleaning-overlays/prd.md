# Fix AirPlay cleaning overlays

## Goal

Ensure Clean Screen creates a visible overlay on every connected display, including AirPlay and Sidecar displays with non-zero global origins.

## Background

The previous multi-display fix reconciled one overlay object per `NSScreen`, but it did not validate real `NSWindow` placement. On the current machine, the Sidecar screen has global frame origin `x=2056`. Passing that global frame to `NSWindow(contentRect:..., screen: sidecar)` causes AppKit to apply the screen origin again and place the window at `x=4112`, outside the display.

## Requirements

- Create a new overlay window with a screen-local content rectangle whose origin is zero and whose size matches the target display.
- Keep topology updates using the display's global frame through `setFrame`.
- Preserve screen-saver level, all-Spaces behavior, black opaque content, shared controller state, countdown, and exit behavior.
- Add deterministic regression coverage for non-zero display origins.
- Add a real-window test that verifies a non-primary `NSScreen` receives the expected global frame and display identity; skip only when no non-primary display is connected.
- Do not display a black overlay during automated tests.

## Acceptance Criteria

- [x] A target frame at a non-zero origin produces a local window content rect at `.zero` with the same size.
- [x] On the connected Sidecar/AirPlay display, an unpresented overlay window reports the Sidecar screen ID and exact global frame.
- [x] Existing display reconciliation tests pass.
- [x] The full Swift test suite and packaged app build pass.
- [x] A live transparent probe confirms both connected displays receive correctly placed visible windows.

## Out of Scope

- Changing cleaning mode visuals or duration.
- Changing keyboard-cleaning input interception.
- Refactoring unrelated Quick Actions.
