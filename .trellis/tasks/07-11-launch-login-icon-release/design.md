# Design: launch at login, app icon, and release

## Launch-at-login boundary

Add `LaunchAtLoginService` under `Sources/TouchMacer/` and link Apple's `ServiceManagement` framework.

The service wraps `SMAppService.mainApp` and maps framework states into an app-owned enum:

- disabled ← `notRegistered`
- enabled ← `enabled`
- requires approval ← `requiresApproval`
- unavailable ← `notFound`

Registration state stays in macOS Service Management. Do not mirror it in `AppSettings` or `UserDefaults`.

`setEnabled(true)` calls `register()`. `setEnabled(false)` calls `unregister()`. After either operation or failure, refresh from `SMAppService.mainApp.status` so the UI never reports requested state as actual state. Expose `SMAppService.openSystemSettingsLoginItems()` for approval-required recovery.

`AppModel` owns the service, publishes current status and a focused error message, and exposes enable/disable, refresh, and open-settings actions. Settings refresh status on appearance because the user may change Login Items while TouchMacer is running.

## Settings UI

Add a compact Startup group to the existing About pane instead of introducing a new sidebar destination for one setting.

- Toggle label: `Launch TouchMacer at login`
- Enabled state includes both `enabled` and `requiresApproval`, because the app remains registered in both states.
- Approval-required state shows an orange explanation and `Open Login Items Settings` button.
- Unavailable state disables the toggle and explains that the app must run from a packaged application bundle.
- Errors render inline and do not reuse Calendar authorization copy.

## Icon

Create one 1024×1024 PNG source asset at `assets/AppIcon.png`:

- dark neutral rounded-square field
- minimal white clock face/hand geometry
- one cyan touch/pulse accent
- no text, tiny details, or photographic texture
- strong silhouette at menu and Finder sizes

The packaging script generates a complete `.iconset` with `sips`, compiles it using `iconutil`, copies `AppIcon.icns` to `Contents/Resources`, and adds `CFBundleIconFile=AppIcon` to `Info.plist`.

Generated iconset intermediates remain under `.build` and are not committed. The 1024×1024 source asset is committed.

## Bundle and local behavior

Update `scripts/build-app.sh` to:

1. build release binary
2. create `Contents/MacOS` and `Contents/Resources`
3. copy the executable
4. generate/copy `AppIcon.icns`
5. write version 0.1.3, build 4, and the icon declaration
6. ad-hoc sign the completed local bundle so Service Management receives a stable packaged application during local verification

The release zip contains the app bundle, not build intermediates.

## Release

Create one task-owned commit after verification, push `master`, create tag/release `v0.1.3`, and upload `TouchMacer-v0.1.3-macos.zip`.

Release notes cover:

- Launch at Login control using macOS Service Management
- new TouchMacer icon
- packaging and local startup improvements

Do not stage pre-existing untracked `.agents`, `.claude`, `.codex`, `.cursor`, `.serena`, `.spec-workflow`, `.trellis`, or root `AGENTS.md` paths as a side effect of the product release.

## Verification

- unit-test service status mapping and AppModel transitions through a fake service boundary
- `swift build`
- focused `swift test`
- build app bundle
- inspect Info.plist and icon resources
- render icon at required sizes
- open app bundle and confirm the process/menu-bar app remains running
- verify GitHub release metadata and asset after publication
