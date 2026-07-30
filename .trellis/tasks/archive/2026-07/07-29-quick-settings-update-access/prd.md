# Add quick settings and update access

## Goal

Make Settings and update checks directly reachable from MenuCue's most-used surfaces.

## Requirements

- Add a dedicated gear button to the right side of the popover footer, next to the existing overflow menu.
- Clicking the gear closes the popover through the existing callback and opens Settings.
- Add a Check for Updates item to the status-item right-click menu.
- Disable the update item when `UpdateService.canCheckForUpdates` is false.
- Opening Settings switches the app activation policy to `.regular` so MenuCue appears in the Dock.
- Closing the Settings window restores `.accessory` so MenuCue returns to menu-bar-only behavior.
- Preserve the existing overflow menu, context-menu actions, status clock interaction, and update flow.

## Acceptance Criteria

- [x] Popover footer shows a dedicated settings icon with tooltip and accessibility label.
- [x] Right-click menu exposes Check for Updates and routes to `UpdateService.checkForUpdates()`.
- [x] Settings window is Dock-visible while open and returns to accessory mode when closed.
- [x] Focused tests cover the update item and Dock activation policy transitions.
- [x] Full tests and packaged app build pass.
