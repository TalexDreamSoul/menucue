# Implementation plan: launch at login, icon, and v0.1.3 release

## 1. Add Service Management support

- Link `ServiceManagement` in `Package.swift`.
- Add the launch-at-login status model and service wrapper.
- Inject the service into `AppModel` and publish real status/error state.
- Add enable, disable, refresh, and open-System-Settings actions.

Smoke test the service from a packaged app before expanding the UI.

## 2. Add the settings control

- Add a Startup group to the About settings pane.
- Bind the toggle to `AppModel` actions rather than persistent app settings.
- Handle enabled, disabled, approval-required, unavailable, and error states.
- Refresh status when the pane appears.

Smoke test enable/disable and approval messaging from the app bundle.

## 3. Create and package the icon

- Generate `assets/AppIcon.png` at 1024×1024.
- Update `scripts/build-app.sh` to generate all macOS iconset scales, compile `AppIcon.icns`, copy it into the app resources, and declare it in Info.plist.
- Add ad-hoc signing after bundle assembly.
- Bump bundle version to 0.1.3 (build 4) and update the source fallback version.

Smoke test Finder/app icon rendering and local app startup.

## 4. Cleanup after behavior works

- Delegate focused test authoring for the new observable contracts.
- Update README feature/build notes and release-facing version copy only after the app works locally.
- Remove temporary icon generation artifacts outside `.build`.

## 5. Verify and release

Run:

```bash
swift build
swift test --filter TouchMacerTests
./scripts/build-app.sh
open .build/app/TouchMacer.app
```

Then:

- verify the app process remains running
- inspect packaged version and icon keys
- create `TouchMacer-v0.1.3-macos.zip`
- stage only task-owned paths
- commit and push `master`
- publish GitHub release `v0.1.3` with the zip
- verify release tag, URL, and asset metadata

## Review gates

- System Service Management is the single source of truth.
- No `UserDefaults` launch-at-login flag exists.
- Errors cannot leave the toggle showing an unverified requested state.
- The icon pipeline is deterministic from one committed 1024×1024 source.
- The GitHub artifact contains the packaged icon and version 0.1.3.
- Unrelated pre-existing untracked paths are not included in the product commit.
