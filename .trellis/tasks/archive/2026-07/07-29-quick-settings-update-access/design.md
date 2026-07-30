# Design

- `PopoverFooter` adds a plain icon button before its existing overflow `Menu` and reuses `openSettings`.
- `StatusContextMenuItemFactory` builds the localized update item so target/action/enabled wiring is independently testable.
- `StatusBarController` inserts the update item in its existing context menu and invokes `UpdateService.checkForUpdates()`.
- `SettingsWindowDockController` owns activation-policy transitions through an injected closure. Production uses `NSApp.setActivationPolicy`; tests record requested policies without mutating the test process.
- `StatusBarController` becomes the Settings window delegate, switches to `.regular` before presentation, and restores `.accessory` in `windowWillClose`.
