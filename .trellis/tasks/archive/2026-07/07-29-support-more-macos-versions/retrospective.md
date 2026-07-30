# Retrospective

## Decision

macOS 13 Ventura is the lowest maintainable target. It preserves the app's existing `SMAppService`, `NavigationSplitView`, and SwiftUI `Layout` architecture. macOS 12 would require parallel implementations of the privileged Helper lifecycle, settings navigation, and layout system.

## Compatibility work

- Lowered SwiftPM and app bundle minimum versions to 13.0.
- Added shared availability-gated View modifiers for macOS 13.3/14-only presentation and keyboard APIs.
- Reused the compatible single-parameter `onChange` behavior at all current call sites.
- Added an EventKit authorization fallback for Ventura.
- Replaced the macOS-14-only empty state with ordinary SwiftUI.
- Enabled deterministic JSON key ordering after the lower target exposed unstable byte comparisons in wake-history persistence.
- Added bounded notarization retries after Apple's service returned a transient 503 while still failing closed after the configured attempt limit.

## Verification

- Clean macOS 13-targeted compilation succeeded with no unavailable-API errors.
- 382 XCTest tests and 4 Swift Testing tests passed.
- Product tests assert both SwiftPM and bundle minimum-version metadata.
- Final app and Helper Mach-O load commands report `minos 13.0`.
- Final appcast reports `minimumSystemVersion=13.0`.
- Notarization submission `f888d8e5-0d25-43fd-ba10-63b4d807a015` returned Accepted.
- The app extracted from the final ZIP passed strict codesign, stapler validation, and Gatekeeper assessment.
- Final ZIP SHA-256: `e01a5e460cd84d39002ae5a2371ef2cf55deb31832bf24b5a7d2b86b1983d563`.
