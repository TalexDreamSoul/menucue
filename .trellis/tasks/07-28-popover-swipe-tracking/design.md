# Design: configurable popover tabs and swipe navigation

## Boundaries

The feature stays inside the existing settings/runtime boundaries:

- `PopoverTab` is the stable built-in tab identity and becomes `Codable`.
- `AppSettings` owns the normalized ordered collection.
- `SettingsStore` persists raw tab IDs in local `UserDefaults`.
- `AppModel.updateSettings` remains the only mutation boundary.
- `StatusPopoverView` and `PopoverTabBar` consume the ordered collection.
- `SwipeForwardingView` remains the AppKit event boundary; `SwipeRecognizer` remains the gesture decision boundary.

No iCloud schema, Helper protocol, permissions, or notification contracts change.

## Data contract

Add a local preference key such as `popoverTabOrder.v1`, storing an array of stable raw IDs:

```text
["status", "calendar", "power", "actions"]
```

Normalization is total and lossless for known values:

1. Keep the first occurrence of each known ID in stored order.
2. Ignore unknown IDs individually.
3. Append every missing current `PopoverTab.allCases` item in product-default order.
4. An absent or malformed preference resolves to all current tabs in default order.

This guarantees that ordering can never hide a built-in tab and that a future app version can add a tab without migration code.

## Settings interaction

Add a `Popover Tabs` group to the existing Overview settings pane. It uses the same native macOS `List` + `.onMove` interaction already used by the clock carousel:

- drag handle
- localized tab title
- existing SF Symbol
- no enable/disable control
- short caption explaining that the first row is the startup default and horizontal swipes follow this order

A reorder calls an `AppModel` method, persists immediately, and publishes the new `AppSettings`, so an already-open popover updates without reopening Settings.

## Navigation contract

`StatusPopoverView` derives one ordered `tabs` value from `model.settings.popoverTabOrder`. Every navigation path uses it:

- `PopoverTabBar` rendering
- tab-click animation direction
- left/right arrow movement
- `SwipeRelay` commands
- card deep-links such as Status to Actions

The first tab initializes `selectedTab` when the view is created after app launch. Because the existing hosting controller is retained across popover presentations, later opens preserve the selected state for that session.

Movement wraps at both ends. A leftward finger flick reveals the next tab to the right in configured order; the reverse flick reveals the previous tab.

## Gesture delivery

Keep the existing vertical-scroll safety contract:

- inject one shared `SwipeRelay` into both the AppKit container and the observing SwiftUI view
- only opt into horizontal swipe/forwarded scroll events
- precise vertical-dominant events pass to the hosted scroll view
- one recognized gesture emits one sequence-numbered relay command
- momentum after a recognized gesture is consumed

Do not add an app-wide event monitor or Accessibility permission. Real-trackpad logs showed the ancestor container emitting `navigate(...)` while SwiftUI observed a separately allocated relay; sharing one injected relay fixes delivery without changing gesture thresholds or vertical-dominance behavior.

## Compatibility

Existing users have no stored tab order and receive the Status, Calendar, Power, Actions order. Corrupt values recover automatically. The preference remains machine-local.

## Verification

Automated tests cover normalization, persistence, arbitrary reorder, default-first navigation, wraparound, repeated swipe relay commands, and vertical-scroll pass-through. Final acceptance also requires one real two-finger gesture while running with `MENUCUE_SWIPE_LOG=1`; synthetic events are not accepted as evidence.

## Rollback

Removing the new key and reverting consumers to `PopoverTab.allCases` restores current behavior. Existing stored raw IDs are harmless if an older build reads the same defaults domain.
