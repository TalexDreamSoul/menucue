# Implementation plan: configurable quick actions and v0.2.0

## 1. Add the action model and persistence boundary

- Add `QuickActionModels.swift` with stable built-in IDs, persisted built-in/Shortcut references, action kinds, metadata, availability, and state.
- Add ordered pinned reference storage to `AppSettings` and `SettingsStore`.
- Default new installations to the seven PRD-defined actions.
- Add `AppModel` add/remove/reorder methods enforcing uniqueness, availability, and the seven-item limit.

Smoke check: load empty defaults, save a mixed built-in/Shortcut order, reload it, and confirm malformed references do not remove valid neighbors.

## 2. Implement runtime actions

- Add `QuickActionService.swift` and fixed process execution helpers that never invoke a shell.
- Reuse `AppearanceService` for dark-mode query/set and observe external theme changes.
- Implement display sleep, lock screen, keep awake, screen saver, desktop icons, Dock auto-hide, menu-bar auto-hide, and empty trash.
- Add availability-only states for low power mode, lid-closed wake, and hide-notch when ordinary permissions cannot satisfy the contract.
- Add cleaning overlays, countdown, Escape hold, mouse exit, keyboard event tap, and cleanup on teardown.

Smoke check each non-destructive action independently before connecting it to the full UI. Verify every requested toggle by re-reading the system state after mutation.

## 3. Integrate Apple Shortcuts

- Discover via `shortcuts list`.
- Execute via `shortcuts run <exact-name>`.
- Represent missing or renamed pinned shortcuts without crashing.
- Keep discovery/execution failures isolated from built-in actions.

Smoke check with the local Shortcut catalog and one harmless existing Shortcut.

## 4. Add reusable quick-action UI

- Add `QuickActionViews.swift` with tiles, four-column compact grid, state styling, accessibility, feedback, and destructive confirmation.
- Insert the configured grid before World Clocks.
- Append the fixed More tile after configured actions.
- Increase the popover to 320×680 and preserve existing calendar, daily guide, and event sections below it.

Smoke check popover layouts with zero, four, six, and seven pinned actions and with long Shortcut names.

## 5. Add the independent catalog window

- Add `QuickActionsWindowView` with all built-ins, discovered Shortcuts, state, availability explanations, and Manage action.
- Add singleton window ownership to `StatusBarController`.
- Wire the popover More tile to open/raise that window.

Smoke check repeated More clicks reuse one window and unavailable actions explain rather than execute.

## 6. Add Settings configuration

- Add a Quick Actions sidebar pane.
- Add ordered selected rows with move-up/down/remove controls.
- Add the available built-in and Shortcut catalog with Add controls.
- Disable Add at seven, prevent duplicates, and persist immediately.

Smoke check reorder, remove, add, maximum count, unavailable actions, and immediate popover reflection.

## 7. End-to-end verification

After the complete behavior works:

```bash
swift build
swift test
./scripts/build-app.sh
open .build/app/TouchMacer.app
```

Manual gates:

- popover shows 7 configured actions plus More in a 4×2 grid
- external dark-mode changes update within one second
- More opens one independent window
- Settings persists add/remove/reorder across relaunch
- Apple Shortcuts discover and a harmless Shortcut executes
- keep-awake and cleaning modes always release on exit
- empty trash always asks for confirmation
- unavailable low-power, lid, or notch actions never claim success
- existing world clocks, calendar selection, daily guide, event creation, launch at login, and update check still work

## 8. Cleanup after behavior works

- Update README feature and packaging notes.
- Bump `scripts/build-app.sh` to v0.2.0/build 5 and the source fallback version to 0.2.0.
- Remove temporary artifacts outside `.build`.
- Run final diagnostics, build, tests, packaged launch, and visual verification.

## 9. Commit and release

- Build `.build/app/TouchMacer.app` and package `TouchMacer-v0.2.0-macos.zip`.
- Stage only intended product paths; do not include unrelated agent/bootstrap directories.
- Commit the verified feature and push `master` to `origin`.
- Create GitHub release `v0.2.0` with the zip and concise release notes.
- Verify the remote tag, release URL, asset name, size, and downloadability.
- Download the release asset into a clean local directory, unzip it, replace `/Applications/TouchMacer.app`, launch it, and verify bundle version 0.2.0 and the running process path.

## Review gates

- `QuickActionService` is the sole runtime action executor.
- `UserDefaults` stores only ordered references, never inferred runtime state.
- No user text enters a shell command.
- No `sudo`, privileged helper, private API, or kernel extension is introduced.
- Unsupported capabilities remain explicit disabled catalog items.
- Temporary input/sleep effects have deterministic cleanup paths.
- The release asset contains the verified v0.2.0 app bundle.
