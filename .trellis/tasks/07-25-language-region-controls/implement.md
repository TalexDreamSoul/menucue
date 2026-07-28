# Implementation plan: app language and system region controls

## Prerequisite

- Installed `/Applications/TouchMacer.app` is remote `v0.4.0`, updater configuration is healthy, and no process/build command will overwrite it.
- `v0.4.1` work occurs only in the repository and `.build` until the OTA install action.

## 1. RED: language ownership and resources

- Add tests for System Default/English/zh-Hans resolution, local persistence, unsupported-value normalization, AppleLanguages override mapping, and exclusion from portable iCloud fields.
- Add key-parity tests that fail when English and zh-Hans resource tables differ.
- Add relaunch coordinator tests for success/failure without launching real processes.
- Confirm focused tests fail before implementation.

## 2. GREEN: app language service and pane

- Add TouchMacer target resources and `AppLanguageService` with injected defaults/relauncher seams.
- Inject the service through `AppModel` and add `Language & Region` to settings navigation.
- Implement System Default, English, and 简体中文 segmented/picker control with explicit relaunch behavior and error feedback.
- Update `scripts/build-app.sh` to copy the SwiftPM resource bundle and verify both `.lproj` localizations exist in the packaged app.

## 3. Localization audit

- Inventory all user-facing strings in `Sources/TouchMacer` and classify translatable vs technical/user content.
- Route computed/interpolated/AppKit/helper strings through the localization access layer.
- Populate complete English and zh-Hans tables; preserve IANA IDs, custom labels, format tokens, Shortcut names, and URLs.
- Run key-parity tests and targeted UI width checks for both languages. Verify sidebar, buttons, alerts, status text, and compact panels do not truncate or overlap.

## 4. RED: v0.4.0 Helper capability consumption

- Reuse the protocol version, capabilities, and typed time-zone query/set RPC already shipped and tested in v0.4.0; v0.4.1 may not add an XPC selector.
- Add feature-layer tests for unavailable/approval/capability-mismatch/error/observed-mismatch/success states without invoking real SMAppService.
- Add a compatibility fixture proving a long-running v0.4.0 helper accepts the stably signed v0.4.1 client requirement.
- Confirm feature tests fail before UI/service integration.

## 5. GREEN: system time-zone control

- Connect the new pane to the existing v0.4.0 time-zone RPC and capability negotiation.
- Keep root/client requirement checks, fixed executable validation, observed-result verification, and existing power operations unchanged.
- Implement searchable picker, observed current zone, apply state, localized progress/result, and helper remediation in the new pane.
- Subscribe to system time-zone changes and refresh app time-driven views after a verified change.
- Add the safe macOS Language & Region deep-link action.

## 6. Full verification before release

- Run focused tests, `swift test`, release build, and `scripts/build-app.sh`.
- Verify localization resources, helper protocol/binary, LaunchDaemon plist, Sparkle framework, rpaths, Info.plist updater keys, and deep code signatures.
- Do not launch any local v0.4.1 executable under the proof user account. Pre-release checks are unit/integration tests, localization key/format parity, static packaged-resource inspection, binary/rpath inspection, and signature verification only.
- First live English/zh-Hans UI inspection on the proof account happens after the OTA relaunch; any pre-release visual run requires a separately approved isolated VM/user or distinct test bundle ID/service/defaults domains.

## 7. Publish v0.4.1 without touching installed v0.4.0

- Set version `0.4.1`, build `10`.
- Generate the versioned ZIP with the same stable signing identity as v0.4.0 and update the dedicated `appcast-feed` signed asset with immutable v0.4.0/v0.4.1 archive entries as needed.
- Verify feed/archive signatures and tamper rejection.
- Stage only feature-owned product/resources/tests/docs/scripts; commit and push `master`.
- Publish GitHub Release `v0.4.1` with ZIP and signed `appcast.xml`; verify tag/commit, latest feed, asset SHA/size, and signatures.
- Update Homebrew cask only after the OTA proof or without invoking local brew upgrade.

## 8. Live OTA proof

- Record installed path/version/build/process hash for v0.4.0.
- Prove scheduled background behavior separately: clear/backdate `SULastCheckTime`, relaunch installed v0.4.0, and observe the automatic feed check/download while recording that the configured interval remains 43200 seconds.
- After background preparation, use manual **Check for Updates** only to resume/show the already downloaded update in Sparkle's native UI; do not claim that the manual check proves scheduling.
- Pause for the user's single **Install and Relaunch** click if UI automation cannot safely access the native window.
- After relaunch, verify `/Applications/TouchMacer.app` is v0.4.1 build 10, process path is `/Applications`, archive/code signatures are valid, and language pane exists.
- Change app language and verify relaunch/persistence.
- Before changing the system time zone, present original and target zones for explicit approval; apply, verify, restore original, and verify restoration.
- Record all evidence in the parent task and report any gap rather than substituting a manual install.

## Validation commands

```bash
swift test
swift build -c release
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 .build/app/TouchMacer.app
find .build/app/TouchMacer.app/Contents/Resources -path '*.lproj*'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/TouchMacer.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/TouchMacer.app/Contents/Info.plist
pgrep -fl TouchMacer
```

## Guardrails

- No undocumented global language mutation.
- No unvalidated identifier reaches root helper execution.
- No false success before observed time-zone verification.
- No private Sparkle key in repository-visible surfaces.
- No manual replacement of installed v0.4.0 and no local v0.4.1 process under the proof account before OTA completion.
- Restore any test system time-zone change before task completion.
