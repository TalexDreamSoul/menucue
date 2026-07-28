# Launch at login icon and GitHub release

## Goal

Ship TouchMacer v0.1.3 with a native launch-at-login control, a simple recognizable macOS app icon, a verified local app-bundle launch, and a GitHub release artifact.

## Requirements

- Add a Launch at Login toggle backed by `SMAppService.mainApp`; the system service status is authoritative and is not duplicated in `UserDefaults`.
- Represent enabled, disabled, approval-required, and unavailable states without claiming success when macOS rejects registration.
- Provide a direct route to System Settings Login Items when approval is required.
- Keep the control usable only from an app bundle; `swift run` may report the capability unavailable.
- Add a simple, text-free TouchMacer icon that remains recognizable from 16×16 through 1024×1024.
- Package the icon into `TouchMacer.app` and declare it through `CFBundleIconFile`.
- Bump the app version from 0.1.2/3 to 0.1.3/4, following the repository's existing patch-release convention.
- Build and launch the app bundle locally before release.
- Commit only task-owned source, asset, packaging, test, and release-note changes; leave pre-existing untracked tool/Trellis bootstrap files untouched.
- Push the release commit to `origin/master`, create tag `v0.1.3`, and publish `TouchMacer-v0.1.3-macos.zip` on GitHub.

## Acceptance Criteria

- [ ] The packaged app exposes a Launch at Login toggle and reflects `SMAppService.mainApp.status`.
- [ ] Enabling registers the main app; disabling unregisters it; errors remain visible and the UI refreshes to the real status.
- [ ] Approval-required state offers a System Settings action.
- [ ] The built app contains `Contents/Resources/AppIcon.icns`, and `Info.plist` declares the icon.
- [ ] The generated icon is visually legible at 16×16, 32×32, 128×128, and 1024×1024.
- [ ] Focused tests and `swift build` pass.
- [ ] `.build/app/TouchMacer.app` launches locally and remains running as a menu-bar app.
- [ ] The release commit is pushed to `origin/master`.
- [ ] GitHub release `v0.1.3` is published with the macOS zip artifact and concise release notes.

## Out of Scope

- iCloud preference sync.
- Replacing GitHub distribution with the Mac App Store.
- A full brand identity or multi-concept icon system.
