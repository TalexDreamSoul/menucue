# Automatic background updates with one-click install

## Goal

Replace the manual GitHub-release check with a secure macOS update experience that checks every 12 hours, prepares new versions with minimal interruption, and lets the user complete an update with one explicit action.

## Background

- The current About pane calls GitHub `releases/latest`, reports whether a newer semantic version exists, and opens the release page. It does not download, verify, install, or relaunch the app.
- TouchMacer is a SwiftPM macOS 14 menu-bar app assembled by `scripts/build-app.sh` and distributed as an ad-hoc-signed ZIP through GitHub Releases and Homebrew.
- Replacing a running app safely requires archive signing, integrity verification, installation coordination, and relaunch handling. This must use Sparkle 2 rather than custom file replacement logic.
- Sparkle's standard automatic-download mode also schedules the downloaded update for installation when the app quits. Sparkle does not provide a standard mode that both downloads automatically and categorically forbids install-on-quit.

## Requirements

- Use the current stable Sparkle 2 release as the update engine.
- Enable automatic checks and background downloads by default, schedule checks approximately every 12 hours, and preserve a user-triggered **Check for Updates** action.
- Let users disable automatic checks and background downloads together in the About pane without disabling manual checks.
- Detect, download, verify, install, and relaunch updates without sending users to a browser or requiring them to replace the app manually.
- Download valid updates automatically after scheduled checks. Offer one explicit user-facing action for immediate install and relaunch; if the user does not act, allow Sparkle to install the prepared update when TouchMacer quits.
- Publish a signed appcast and EdDSA-signed update archive from the existing GitHub release workflow.
- Keep the update signing private key outside Git, logs, release notes, app bundles, and appcast output.
- Replace the custom GitHub update checker so there is one authoritative update state and workflow.
- Use Sparkle's native update window to present release notes and the one-click **Install and Relaunch** action; keep scheduling controls, manual check, last-check information, and concise status in the About pane.
- Preserve local-only preference storage, Homebrew installation, Launch at Login, the privileged helper bundle, and optional iCloud entitlements; use one stable Apple Development signing identity for both OTA releases because ad-hoc CDHash requirements are not stable across updates.
- Pre-ship a versioned/capability-based typed time-zone Helper RPC in v0.4.0 so v0.4.1 adds no selector to a long-running older daemon.
- Do not persist Sparkle-owned scheduling or download state in `AppSettings` or synchronize it through iCloud.

## Acceptance Criteria

- [ ] A packaged app enables automatic checks and background downloads by default and schedules checks at a 12-hour interval.
- [ ] Users can disable or re-enable scheduled checks and background downloads; manual checks remain available either way.
- [ ] The About pane can trigger an immediate update check and accurately reflects update progress and errors.
- [ ] A newer signed release can be obtained without opening GitHub in a browser.
- [ ] One user action installs a prepared update and relaunches TouchMacer; leaving it untouched allows installation on a later app quit.
- [ ] Invalid archive signatures, modified appcasts, malformed feeds, offline requests, and non-newer versions do not install.
- [ ] The generated app bundle embeds and correctly signs every required Sparkle component.
- [ ] The release process publishes a valid appcast entry, archive URL, version/build metadata, size, and EdDSA signature.
- [ ] Existing app behavior and tests continue to pass.
- [ ] A real two-version end-to-end update test succeeds from an older packaged build to a newer packaged build.

## Release Boundary

- This child ships as `v0.4.0` and is manually installed once because `v0.3.1` cannot perform an OTA update.
- The stable feed URL is the `appcast.xml` asset on a dedicated `appcast-feed` prerelease/tag; ordinary latest product releases cannot redirect it. Release archives and the appcast are both EdDSA signed.
- Sparkle scheduling and download preferences remain local in Sparkle-owned defaults.

## Out of Scope

- Building a custom updater or privileged installer.
- Delta updates in the first version.
- Beta channels, staged rollout, or mandatory updates.
- macOS versions older than 14.
- Apple notarization or Developer ID migration in this task.
