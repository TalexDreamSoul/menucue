# Configure popover tab order and swipe navigation

## Goal

Let users arrange the popover's four primary tabs in Settings and move through that configured order with a two-finger horizontal trackpad gesture.

## Background

- Existing users without a stored preference start with Status, Calendar, Power, Actions.
- `PopoverTab.allCases` currently defines rendering, click animation direction, arrow-key navigation, and swipe navigation in `Sources/MenuCue/StatusPopoverView.swift`.
- A shared `SwipeForwardingView` and tested `SwipeRecognizer` already exist, but real-trackpad delivery is still not accepted as complete after several failed implementations.
- `AppSettings`, `SettingsStore`, and `AppModel.updateSettings` are the authoritative persisted-settings boundary.

## Requirements

- Settings exposes all four popover tabs in a native reorderable list, using the same localized labels and SF Symbols as the tab bar.
- Reordering persists locally, updates an open popover immediately, and survives relaunch.
- Stored data is normalized so missing, duplicate, or unknown IDs cannot hide a built-in tab; new future tabs append after valid stored entries.
- The tab bar, direct tab selection, left/right arrow keys, and horizontal swipes all use the configured order and wrap at both ends.
- A two-finger horizontal flick over any popover tab moves exactly one tab in the configured direction with the existing slide animation.
- Vertical scrolling inside Status, Calendar, Power, and Actions remains untouched.
- Horizontal mouse-wheel input keeps working.
- Tab ordering is machine-local in this scope; do not add it to iCloud portable settings.
- The first configured tab is the initial tab after app launch; reopening the popover in the same app session keeps the last selected tab.

## Acceptance Criteria

- [x] Settings can move every popover tab to any position without hiding or duplicating tabs.
- [x] The configured order persists across `SettingsStore` save/load and app relaunch.
- [x] Corrupt or forward-version stored order normalizes to all known tabs exactly once.
- [x] The visible tab bar updates immediately to match the configured order.
- [x] The first configured tab is selected on the first popover presentation after app launch; later presentations in the same session retain the last selected tab.
- [x] Clicking, arrow keys, mouse-wheel horizontal input, and trackpad swipes navigate through that same order and wrap correctly.
- [x] One real trackpad gesture is observed changing exactly one tab in the intended direction with `MENUCUE_SWIPE_LOG=1`.
- [x] Vertical scrolling remains functional in every scrollable tab.
- [x] Localization parity, focused tests, full `swift test`, and `swift build` pass.

## Out of Scope

- Hiding or disabling built-in tabs.
- Per-tab keyboard shortcuts.
- iCloud synchronization of tab order.
- Reordering Settings sidebar panes or Dashboard sections.
