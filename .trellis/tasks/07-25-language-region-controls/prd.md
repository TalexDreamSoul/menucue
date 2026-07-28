# App language and system region controls

## Goal

Deliver English and Simplified Chinese TouchMacer UI plus safe system region controls as the first feature release installed through TouchMacer's new OTA updater.

## Background

- The app currently contains roughly 560 inline string literals and no localization resources.
- SwiftUI string-literal controls can use bundle localization automatically, while AppKit menus, alerts, interpolated status text, errors, and helper feedback require explicit localized formatting.
- App-specific language can be stored in TouchMacer's own defaults domain and applied after an app relaunch; it must remain local and outside iCloud preference sync.
- Changing the macOS system time zone requires root privileges and consumes the versioned/capability-based typed XPC contract pre-shipped in the v0.4.0 SMAppService helper.
- macOS exposes no supported public API for directly changing the global system language from a third-party app. Global language changes also require logout/restart, so the safe integration is a direct link to the Language & Region settings pane.

## Requirements

- Ship this child as `v0.4.1`, after `v0.4.0` is installed and running.
- Add a dedicated **Language & Region** settings pane.
- Support complete English and Simplified Chinese localization for visible navigation, settings, popovers, context menus, alerts, Quick Actions, updater controls, status/error text, and helper feedback.
- Default to the system-preferred supported language when no explicit app language is stored.
- Let the user select **System Default**, **English**, or **简体中文** for TouchMacer.
- Persist app language locally, never in `AppSettings` or iCloud, and relaunch TouchMacer once to apply a changed language.
- Show the current macOS time zone and a searchable list of valid `TimeZone.knownTimeZoneIdentifiers`.
- Change the system time zone through the privileged helper using the typed RPC already shipped in v0.4.0, strict identifier validation, fixed `/usr/sbin/systemsetup` executable, argument arrays, observed-result verification, and localized success/failure feedback; v0.4.1 adds no Helper selector.
- Reuse the existing helper approval and remediation UI; never shell-interpolate a time-zone identifier.
- Provide a one-click action that opens the macOS Language & Region settings pane for global system language changes; do not write undocumented global defaults.
- Preserve clocks, appearance time zones, calendar behavior, updater state, power actions, Launch at Login, and helper security validation.
- Do not run a local v0.4.1 executable under the proof user account before Sparkle installs and relaunches it from v0.4.0.

## Acceptance Criteria

- [ ] Every user-facing product surface renders in English and Simplified Chinese without mixed-language fallback for supported strings.
- [ ] **System Default**, **English**, and **简体中文** selections persist locally and relaunch into the selected language.
- [ ] App language selection is not uploaded through iCloud preference sync.
- [ ] The current system time zone is shown accurately.
- [ ] Selecting a valid target and invoking the change updates the macOS system time zone and verifies the observed result.
- [ ] Invalid or unavailable identifiers never reach `systemsetup`.
- [ ] Missing helper approval produces a clear install/approval path rather than a false success.
- [ ] Global system language action opens the correct macOS settings pane without writing undocumented global defaults.
- [ ] Existing tests pass and focused localization, persistence, XPC validation, helper command, and fallback tests are added.
- [ ] The feature is installed onto the test Mac only through the `v0.4.0 → v0.4.1` Sparkle OTA path.

## Out of Scope

- Additional app languages in this release.
- Direct undocumented mutation of macOS global `AppleLanguages`.
- Changing region, calendar, measurement system, or keyboard input sources.
- Redesigning existing settings beyond the new pane and localization fit fixes.
