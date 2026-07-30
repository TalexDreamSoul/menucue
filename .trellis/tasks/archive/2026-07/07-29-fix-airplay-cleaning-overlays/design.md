# Design

## Root Cause

`NSWindow(contentRect:styleMask:backing:defer:screen:)` interprets `contentRect` in the target screen's coordinate space. The old code supplied `display.frame`, which is already in global screen coordinates. For a display whose origin is not zero, AppKit added the origin a second time.

## Solution

Introduce `CleaningOverlayWindowFactory` as the single owner of initial AppKit window construction. It creates an unpresented window from:

- content origin: `.zero`
- content size: `display.frame.size`
- target screen: `display.screen`

The controller attaches `CleaningOverlayView` and presents the returned window. Existing coordinator updates continue calling `setFrame(display.frame, display: true)` because `NSWindow.setFrame` consumes global coordinates.

## Testing

- Pure geometry test prevents reintroducing a global origin into initial content rect.
- Real AppKit integration test selects a connected non-primary screen, constructs the unpresented production window, and asserts window screen ID, global frame, level, and visibility state.
- Existing fake coordinator tests continue covering lifecycle and topology reconciliation.

## Compatibility

No persisted state or public API changes. The factory only centralizes existing window attributes and corrects initial placement.
