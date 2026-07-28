# Design: app language and system region controls

## Architecture

Add a dedicated `Language & Region` settings pane backed by two runtime owners:

- `AppLanguageService`: app-specific language selection, local persistence, supported-language resolution, and controlled relaunch.
- Existing `PowerHelperManager` plus the forward-compatible `PowerHelperProtocol` already shipped in v0.4.0: system time-zone query/change through the approved root helper. v0.4.1 adds no XPC selector. The existing helper identity, client designated-requirement validation, SMAppService registration, and fixed executable policy remain intact.

Neither owner mutates `AppSettings`; no language or system time-zone preference is synced through iCloud.

## App localization

Support exactly:

- English (`en`)
- Simplified Chinese (`zh-Hans`)
- System Default (resolves to the first supported language, falling back to English)

Add SwiftPM localization resources under the TouchMacer target and copy the generated resource bundle into the packaged app. Every product string, including SwiftUI labels, resolves explicitly through one localization access layer using `Bundle.module`; do not depend on SwiftUI's main-bundle literal lookup. Dynamic/interpolated strings use typed formatting helpers, and AppKit menus/alerts, errors, helper feedback, and model titles use the same boundary. Add `CFBundleDevelopmentRegion`, supported-localization declarations, duplicate/unreferenced key checks, and English/zh-Hans format-argument parity tests.

The localization audit covers status popover, settings sidebar/content, calendar/event creation, clock/time-zone labels, appearance, iCloud sync, Quick Actions, helper management, context menus, alerts, launch-at-login, updater controls, empty/error/progress states, and release links. Technical identifiers, IANA time-zone IDs, Shortcut names, format patterns, URLs, and user-provided labels are not translated.

`AppLanguageService` stores an app-local enum key. On selection:

1. write/remove the app-domain `AppleLanguages` override corresponding to the explicit choice;
2. persist the explicit enum separately for reliable UI state;
3. launch a new instance from `Bundle.main.bundleURL`;
4. terminate the old instance only after relaunch request succeeds.

System Default removes the app-domain override. This does not mutate macOS global language preferences.

## System time zone

The pane displays `TimeZone.autoupdatingCurrent.identifier`, listens for `NSSystemTimeZoneDidChange`, and provides a searchable picker from `TimeZone.knownTimeZoneIdentifiers`. Search matches identifier and localized display name. The Apply command is disabled when the target is invalid, unchanged, or an operation is running.

Consume the typed query/set methods and capability/version negotiation shipped in v0.4.0. Their reply includes success, observed identifier, and error text. The helper:

- requires root;
- validates the identifier with `TimeZone(identifier:)` and exact membership in `knownTimeZoneIdentifiers`;
- invokes only `/usr/sbin/systemsetup` with argument array `[-settimezone, identifier]`;
- re-reads the active zone with `systemsetup -gettimezone` or Foundation reset/query;
- reports success only when the observed identifier matches the requested identifier.

No shell, AppleScript, string interpolation, arbitrary executable path, or arbitrary arguments cross the XPC boundary.

If the helper is missing/unapproved, reuse registration/approval remediation. A long-running v0.4.0 helper already knows the time-zone RPC, and stable Apple Development signing gives v0.4.0/v0.4.1 the same designated requirement. Capability/version mismatch disables the action and requests Helper refresh rather than sending an unsupported selector. Existing power operations and managed sleep restoration remain unchanged.

## macOS global language

The pane provides a button opening:

`x-apple.systempreferences:com.apple.Localization-Settings.extension`

No code writes `NSGlobalDomain AppleLanguages`, edits login-window defaults, kills user sessions, or claims the global language changed.

## OTA release boundary

This child is version `0.4.1`, build `10`. It is built with the same stable Apple Development identity, archive-signed, feed-signed, committed, pushed, and released while `/Applications/TouchMacer.app` remains the remote `v0.4.0` bootstrap build. Before OTA, no local v0.4.1 executable may run under the proof user account; pre-release validation is limited to unit/integration tests, static resource inspection, binary inspection, and signature checks. First live UI execution of v0.4.1 on the proof account occurs after Sparkle relaunches it.

After release:

1. trigger/check the installed `v0.4.0` updater;
2. observe `v0.4.1` discovery and signed background download;
3. user clicks Sparkle's native **Install and Relaunch** once;
4. verify the relaunched process path, version/build, code signature, language pane, and settings persistence;
5. exercise a safe time-zone round trip only with explicit approval of the concrete before/target/restore zones.

No `brew upgrade`, `cp`, `ditto`, `open` of a locally built v0.4.1, or manual `/Applications` replacement is allowed between publishing v0.4.1 and completing OTA proof.

## Failure and rollback

- Missing translation: English fallback plus test failure in localization key parity.
- Unsupported stored language: normalize to System Default.
- Relaunch failure: keep current process alive and show error.
- Invalid time zone: reject before XPC.
- Helper unavailable/old: show remediation; no false success.
- `systemsetup` failure or observed mismatch: publish localized failure and current observed zone.
- OTA failure: preserve installed v0.4.0, collect Sparkle error, fix with a higher build/appcast; never manually install v0.4.1 to claim success.
- System time-zone test must restore the original zone and verify restoration before completion.
