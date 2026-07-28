# Popover keyboard tab navigation

## Goal

Switch popover tabs with left and right arrow keys while the popover is focused.

## Background

- The popover owns its current selection in `StatusPopoverView.selectedTab`.
- `PopoverTab` defines the ordered Status, Calendar, and Actions tabs.
- The app targets macOS 14, where SwiftUI key-press and focus APIs are available.

## Requirements

- When the status popover receives keyboard focus, Left Arrow selects the previous tab and Right Arrow selects the next tab.
- Navigation wraps at both ends of the tab list.
- Tab changes use the existing `PopoverMotion.navigation` animation.
- Handle unmodified arrow keys only; do not consume modified keyboard shortcuts.
- Preserve mouse selection, scrolling, buttons, menus, and text-entry behavior.
- Keep tab ordering logic independent of SwiftUI so it can be unit tested.

## Acceptance Criteria

- [x] Right Arrow cycles Status to Calendar to Actions to Status.
- [x] Left Arrow cycles Status to Actions to Calendar to Status.
- [x] Arrow navigation works after the popover appears and has focus.
- [x] Modified arrow-key combinations are not consumed by this behavior.
- [x] Existing tab mouse interaction and current controls continue to work.
- [x] Relevant unit tests and the project build pass.

## Out of Scope

- Numeric keypad-specific key-code handling beyond AppKit/SwiftUI's standard left and right arrow events.
- Adding shortcuts for Settings window navigation.
- Changing tab visuals or tab order.

## Notes

- This is a lightweight, PRD-only task.
