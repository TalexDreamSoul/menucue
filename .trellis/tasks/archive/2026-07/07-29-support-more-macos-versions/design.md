# Design

## Minimum-version boundary

macOS 13 is the lowest practical target that preserves MenuCue's architecture. The app depends on `SMAppService` for its privileged Helper and launch-at-login behavior, `NavigationSplitView` for Settings, and SwiftUI `Layout` for settings flow layout; these are macOS 13 foundations. Supporting macOS 12 would require parallel implementations of multiple product subsystems rather than compatibility wrappers.

## SwiftUI compatibility

Introduce narrowly scoped View compatibility modifiers for optional presentation behavior:

- based-on-size scroll bounce is applied on macOS 13.3+ and omitted on 13.0-13.2;
- focus-effect suppression, SF Symbol bounce animation, toolbar sidebar-toggle removal, and SwiftUI key-press handlers are applied on macOS 14+ and omitted on 13;
- accessibility actions and mouse/trackpad navigation remain available on all supported systems.

Replace two-parameter `onChange` closures with the pre-macOS-14 single-parameter overload because current call sites all use the default `initial: false` behavior.

Replace `ContentUnavailableView` with an equivalent ordinary SwiftUI empty state that works on macOS 13.

## EventKit compatibility

Use `requestFullAccessToEvents` on macOS 14+. On macOS 13, use `requestAccess(to: .event)` and map the resulting authorization status through the same model. No persistence format changes.

## Distribution

Bump to v0.6.6 (22), build against macOS 13, sign with Developer ID, notarize, staple, and verify the extracted ZIP. Sparkle appcast generation must record minimum system version 13.0. After GitHub publication, update `TalexDreamSoul/homebrew-tap` Cask metadata and remove the obsolete development-signing caveat.
