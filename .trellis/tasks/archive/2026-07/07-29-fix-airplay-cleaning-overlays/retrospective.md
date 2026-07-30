# Bug Retrospective: AirPlay overlay placed off-screen

## Root Cause Category

- **D — Test Coverage Gap**: coordinator tests proved one abstract overlay per display but never created a real `NSWindow`.
- **E — Implicit Assumption**: the implementation assumed the `contentRect` accepted by `NSWindow(..., screen:)` used global coordinates.

## Why the Previous Fix Failed

The previous change correctly handled display identity and topology events, but its fake overlay factory could not observe AppKit coordinate conversion. Main-screen tests also masked the defect because the main display origin is zero.

## Evidence

- Sidecar target frame: `{{2056, 137}, {1590, 1192}}`, display ID 11.
- Old initializer result: `{{4112, 274}, {1590, 1192}}`, no matching `window.screen` ID.
- Local zero-origin initializer result: exact Sidecar frame and display ID 11.

## Prevention

- Keep initial `contentRect` screen-local and topology `setFrame` global.
- Test pure non-zero-origin geometry.
- Test an unpresented production `NSWindow` against a connected non-primary screen.
- Use a transparent, short-lived production-window probe when physical multi-display evidence is available.
