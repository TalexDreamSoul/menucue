# Design: configurable quick actions and v0.2.0 release

## Architecture

Add one app-owned quick-action subsystem instead of embedding system commands in SwiftUI views.

- `QuickActionModels.swift` owns stable built-in identifiers, persisted references, action metadata, action kinds, availability, and display state.
- `QuickActionService.swift` owns system-state refresh, action execution, Apple Shortcuts discovery/execution, temporary keep-awake state, cleaning overlays, permission checks, and user-visible operation feedback.
- `QuickActionViews.swift` owns the reusable 4-column popover grid, tiles, destructive confirmation, the independent full catalog window, and the quick-action settings content.
- `AppSettings` stores only ordered pinned references. Runtime state remains authoritative in `QuickActionService` and is never mirrored into `UserDefaults`.
- `AppModel` owns one `QuickActionService`, persists pinning changes through the existing `updateSettings` boundary, and exposes add/remove/reorder operations.
- `StatusBarController` owns the independent quick-actions window, just as it already owns settings and quick-event windows.

This keeps each action behind one execution boundary and lets the popover, full catalog, and settings reuse identical metadata and availability.

## Persisted references

Persist ordered strings under one `UserDefaults` key:

- built-in action: `builtin:<stable-id>`
- Apple Shortcut: `shortcut:<exact shortcut name>`

`QuickActionReference` parses only those prefixes. Unknown or malformed values are ignored without discarding other valid entries. Pinning is de-duplicated and capped at seven.

The default ordered set is:

1. dark mode
2. lock screen
3. keep screen on
4. screen saver
5. hide desktop icons
6. auto-hide Dock
7. auto-hide menu bar

A renamed or deleted Shortcut remains representable as a missing pinned reference until the user removes or replaces it.

## Runtime model

`QuickActionService` is an `ObservableObject` with:

- built-in descriptors in fixed catalog order
- discovered Shortcut names
- per-action `QuickActionState` containing availability, current toggle value, running state, and focused failure/remediation text
- one transient feedback message

Opening the popover or catalog starts an asynchronous refresh. Toggle views render the queried system state, not the last requested value. The service observes `AppleInterfaceThemeChangedNotification` and refreshes dark-mode state within one second.

Actions use three execution shapes:

- toggle: query current state, request inverse, query again, publish actual result
- button: execute once and publish success/failure
- mode: enter a managed temporary state with an explicit and timed cleanup path

## Built-in actions

### Public or fixed system mechanisms

- Turn off displays: run fixed `/usr/bin/pmset displaysleepnow` arguments.
- Dark mode: reuse `AppearanceService` system appearance query/set methods.
- Lock screen: send the standard Control-Command-Q shortcut through System Events; surface Automation/Accessibility denial.
- Keep screen on: own a `caffeinate -di` child process and terminate it on toggle-off or service deinit.
- Screen saver: open the packaged system `ScreenSaverEngine.app` if present.
- Hide desktop icons: fixed `defaults` write to Finder plus Finder refresh; re-read actual preference afterward.
- Auto-hide Dock: fixed Dock preference write plus Dock refresh; re-read actual preference afterward.
- Auto-hide menu bar: fixed global preference write plus SystemUIServer refresh; re-read actual preference afterward.
- Empty Trash: enumerate only the current user trash directory with `FileManager`; confirmation stays in the shared tile UI.

### Availability-limited actions

- Low Power Mode: read `ProcessInfo.isLowPowerModeEnabled`; ordinary application permissions do not provide a reliable setter on supported systems, so expose remediation and keep the action unavailable when direct mutation is not permitted.
- Don't Sleep When Closed: remain unavailable unless a public, ordinary-permission mechanism is positively detected; never substitute normal keep-awake behavior.
- Hide Notch: available only when a reliable AppKit-only presentation can be established for a notched built-in screen; otherwise retain a disabled catalog item with an explanation.

### Cleaning modes

`CleaningModeController` creates one borderless screen-saver-level window per active display and owns a 30-second countdown.

- Clean Screen uses a black overlay on every display.
- Clean Keyboard uses the overlay plus a keyboard event tap. It blocks normal key events while leaving mouse input available.
- Clicking Exit or holding Escape for three seconds closes every overlay, stops timers/event taps, and restores normal input.
- Accessibility permission is requested only when Clean Keyboard is selected.
- Service teardown always calls cleanup.

## Apple Shortcuts

Use the system `shortcuts` executable directly with fixed argument arrays:

- `shortcuts list` discovers names.
- `shortcuts run <name>` executes the selected shortcut.

No shell interpolation is used. Shortcut output is not interpreted as executable content. Discovery failures leave built-in actions usable and publish a focused message.

## UI

### Popover

Increase the popover to 320×680 points. Insert `QuickActionGrid` before `World Clocks`.

- four equal columns
- at most seven configured actions
- More is always appended last
- icon above a two-line label
- active toggles use the accent color; inactive buttons use a neutral surface
- unavailable actions cannot be pinned

The existing calendar, daily guide, and event UI remain below the quick-action area in the existing scroll view.

### Independent catalog

`QuickActionsWindowView` uses a resizable window and adaptive grid to show all 14 built-ins plus discovered Shortcuts. It displays state, availability explanations, transient feedback, and a Manage button opening Settings.

### Settings

Add a `Quick Actions` sidebar pane. It contains:

- ordered pinned items with move-up, move-down, and remove controls
- an explicit `n / 7` count
- available built-ins and discovered Shortcuts with Add buttons
- disabled built-ins with their reason

All mutations flow through `AppModel`; views do not write `UserDefaults` directly.

## Compatibility and failure behavior

- Minimum platform remains macOS 14.
- Fixed command execution never uses a shell, `sudo`, a privileged helper, private API, or user-supplied command text.
- Missing executables, permission denial, unsupported hardware, and non-zero process exits become focused UI errors.
- A failed action does not mutate persisted configuration or claim a changed state.
- Existing settings without quick-action keys receive the seven defaults.

## Release

Ship as v0.2.0, build 5.

- update bundle version and source fallback copy
- package and ad-hoc sign `TouchMacer.app`
- create `TouchMacer-v0.2.0-macos.zip`
- commit only product-owned source, packaging, README, and task files intended for the release
- push `master`
- publish GitHub release `v0.2.0`
- download the published asset into a clean local directory, unpack it, install it into `/Applications`, launch it, and verify the running process is the downloaded v0.2.0 bundle

## Rollback

If an action proves unsafe or unreliable during verification, keep its stable identifier and catalog entry but change availability to disabled with an explicit reason. Do not delete identifiers already persisted by users. If the release artifact fails installation or launch, delete the draft release/tag, fix packaging, rebuild, and republish the same version only before external use; otherwise increment the patch version.
