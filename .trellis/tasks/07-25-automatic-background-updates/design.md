# Design: automatic background updates

## Architecture

Use Sparkle 2.9.4 as an exact SwiftPM binary dependency. `UpdateService` is a main-thread `ObservableObject` that strongly owns one `SPUStandardUpdaterController`, exposes the underlying `SPUUpdater` settings as typed UI state, and implements Sparkle updater delegates for concise status/error reporting. `AppDelegate` creates the service before `AppModel`; `AppModel` exposes the service to the existing About pane.

Sparkle remains the only owner of update scheduling, last-check time, skipped versions, downloaded archives, and pending install state. None of these values enter `AppSettings`, `SettingsStore`, portable iCloud fields, or `PreferenceSyncService`.

## Runtime behavior

The packaged Info.plist provides initial defaults:

- `SUFeedURL`: `https://github.com/TalexDreamSoul/touch-macer/releases/download/appcast-feed/appcast.xml`
- `SUPublicEDKey`: the generated Ed25519 public key only
- `SUEnableAutomaticChecks`: `true`
- `SUScheduledCheckInterval`: `43200`
- `SUAutomaticallyUpdate`: `true`
- `SUVerifyUpdateBeforeExtraction`: `true`
- `SURequireSignedFeed`: `true`

The About pane replaces the custom GitHub checker with:

- **Automatically check and download updates** toggle; it writes `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` together.
- **Check for Updates** button calling `SPUUpdater.checkForUpdates()`; it remains available when scheduling is disabled.
- Last-check and concise current/error status text.

Sparkle's standard user driver owns update release notes, download/install progress, permission UI, **Install and Relaunch**, skipped versions, and install-on-quit behavior. No duplicate custom update modal is added.

## Packaging

`Package.swift` pins Sparkle 2.9.4 and links the `Sparkle` product into `TouchMacer`. The executable must resolve `@rpath/Sparkle.framework/...` from `@executable_path/../Frameworks`.

`scripts/build-app.sh` creates `Contents/Frameworks` and copies the complete framework from SwiftPM's resolved binary artifact with symlinks preserved. It must not copy dSYMs or CLI tools into the app. Existing `TouchMacerHelper` and LaunchDaemon paths stay unchanged.

The script verifies:

- `otool -L` references embedded Sparkle via `@rpath`.
- framework symlinks and `Updater.app`, `Autoupdate`, `Installer.xpc`, and `Downloader.xpc` exist.
- nested signatures and outer app pass `codesign --verify --deep --strict`.
- the app launches without a DYLD error.

The app is not sandboxed, so Sparkle downloader/installer launcher service Info.plist keys and app sandbox entitlements are not enabled.

Release builds may not use ad-hoc signing: its designated requirement is a build-specific CDHash and breaks the long-running privileged Helper after OTA replacement. `v0.4.0` and `v0.4.1` use the same available Apple Development identity and are signed from deepest nested code to the outer app. A two-copy signing experiment with different build numbers confirmed the identity yields one stable requirement anchored to the Apple Development certificate. Packaging records and compares identifier, authority/team identity, and designated requirement for the main app, Helper, and Sparkle components. The releases remain non-notarized; this is a continuity mechanism for the controlled/private distribution chain, not a substitute for Developer ID distribution.

## Update signing and appcast

The Sparkle Ed25519 private key is generated once into the macOS login Keychain using Sparkle's `generate_keys`. This is an explicit security gate. Only the public key is committed. The private key is never printed, exported into the repository, or passed through command arguments/logs.

A release helper script receives a directory of versioned ZIP archives and uses tools from the checksum-verified Sparkle 2.9.4 SPM artifact. `generate_appcast` writes archive URL, byte length, `CFBundleVersion`, short version, minimum macOS version, and EdDSA enclosure signature. The final XML is then explicitly signed (or re-signed) with `sign_update`; no bytes may change afterward.

Verification is two distinct operations:

- Extract each enclosure's `sparkle:edSignature` and pass it to `sign_update --verify <zip> <signature>`.
- Run `sign_update --verify appcast.xml` with no external signature, because the signed feed embeds its own signature block.

Every versioned GitHub Release contains its immutable `TouchMacer-vX.Y.Z-macos.zip`. A separate prerelease/tag named `appcast-feed` owns the mutable signed `appcast.xml` asset at the stable feed URL. Publishing updates that asset atomically after all verification; ordinary product releases cannot redirect or remove the feed. Appcast enclosures always use immutable version-tag archive URLs.

## Release and bootstrap

`v0.4.0` is the updater bootstrap release, build 9. Since installed `v0.3.1` has no Sparkle engine, stop it and install `v0.4.0` manually from the verified remote artifact exactly once. Update Homebrew to `0.4.0` after release.

To make the later OTA safe, `v0.4.0` also ships the forward-compatible privileged-helper contract before any UI uses it: `protocolVersion`, declared capabilities, typed system-time-zone query/set RPC, fixed-command validation, and manager negotiation. This prevents `v0.4.1` from sending a new selector to an old v0.4.0 daemon. No language/region UI is exposed in v0.4.0.

The installed `v0.4.0` must then remain in `/Applications` untouched until the `v0.4.1` OTA proof completes. A local v0.4.1 executable may not be launched on the proof user account before OTA.

## Failure behavior

- Missing/malformed feed: show Sparkle error; keep current app.
- Invalid signed feed or archive: reject before extraction/install.
- Offline/timeout: non-destructive failure; future schedule remains active.
- Non-newer build: report current; never downgrade.
- Read-only/unwritable app location: let Sparkle request supported authorization or report failure.
- Interrupted download/install: rely on Sparkle resume and atomic replacement.
- Missing framework/feed/public key: packaging or startup verification fails before release.
- Helper protocol/capability mismatch: disable protected region actions and require Helper refresh; never send an unsupported selector.
- Main app/Helper signing identity mismatch: release gate fails before upload.

## Compatibility and rollback

The updater does not change persisted TouchMacer settings. Rollback before publishing is removal of Sparkle dependency/service/Info keys. After publishing `v0.4.0`, do not rotate or delete the Ed25519 key; a key loss blocks future safe OTA releases. A bad feed is rolled back by restoring a previously valid signed appcast or publishing a higher fixed build, never by modifying an already signed archive in place.
