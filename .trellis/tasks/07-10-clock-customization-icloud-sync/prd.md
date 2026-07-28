# Clock customization and iCloud sync roadmap

## Goal

Improve TouchMacer's menu-bar clock customization and carousel interaction, and deliver production-capable iCloud preference sync while preserving a fully functional local-only GitHub build.

## Background

- The menu-bar clock currently hard-codes `EEE MMM d` and `HH:mm:ss` with an `en_US_POSIX` locale in `StatusBarController`.
- `AppSettings` is persisted locally by `SettingsStore` through `UserDefaults`; no cloud preference store or iCloud entitlement exists.
- Time-zone order already controls rotation order and the fallback clock, but the settings UI cannot reorder entries or assign custom labels.
- EventKit already exposes the user's iCloud and local Calendar events. Preference sync must not duplicate EventKit data, credentials, permissions, or notifications.
- The current GitHub build path creates an ad-hoc-signed app bundle and checks GitHub releases for updates; it must remain usable without iCloud entitlements.
- Apple Developer Program access and an App Store/TestFlight distribution path are now available, so the iCloud preference-sync prerequisite is satisfied.

## Current Release Requirements

### Date and time formatting

- Provide structured controls for clock cycle (`System`, `12-hour`, `24-hour`), seconds on/off, date style (`Hidden`, `System Short`, `Abbreviated`, `ISO`), weekday style (`Hidden`, `Short`, `Full`), and date-before-time/time-before-date ordering.
- Keep date and time as separate styled segments so the existing date capsule remains intact.
- Provide an optional advanced mode with separate Unicode date and time patterns.
- Require the time pattern to render non-empty; allow the date segment to be hidden.
- Show an immediate menu-bar preview, reject invalid or empty active output, warn about excessive width, and provide one-click reset.
- Reset and migration preserve the current `EEE MMM d` plus `HH:mm:ss` behavior.
- Render month, weekday, and day-period text using each Mac's current system locale. Do not persist a fixed locale.

### Time-zone organization

- Represent the system clock and custom clocks in one ordered list. Let users drag the system clock to any position or hide it; the first visible item drives fallback and the whole order drives rotation.
- Let users assign an optional custom city label per time-zone identifier; an empty label falls back to the catalog-derived title.
- Migrate existing settings without visible change by placing the currently enabled system clock first, followed by the existing custom time-zone order.
- Persist formatting, order, and labels locally through the existing settings model and storage path.
- When the pointer is over the status-bar item, vertical mouse-wheel or trackpad scrolling cycles through visible clocks like a wrapping carousel.
- The first gesture-selected clock enters manual mode and suspends timed rotation indefinitely; choosing `Auto Rotate` from the existing context menu explicitly resumes timed rotation.
- Ignore incidental micro-scroll input and inertial bursts so one deliberate gesture advances at most one clock within a short cooldown.

## iCloud Preference Sync

- Add opt-in iCloud key-value preference sync for entitlement-enabled App Store/TestFlight builds; builds without the entitlement remain local-only and do not show a misleading enable control.
- Keep `SettingsStore` as the authoritative local persistence boundary. A separate sync service imports and exports only the portable subset through `AppModel`.
- Portable scope: date/time presentation, ordered clock identities and custom labels, rotation interval, overview time zone, week-start day, and in-app appearance mode.
- Device-local scope: EventKit data and authorization, selected calendar identifiers, the macOS system-appearance control switch, sync enablement and onboarding decisions, pinned Quick Actions, and transient UI/runtime state.
- Ask once whether to enable sync on the first launch of an entitlement-enabled build.
- If both local and iCloud stores already contain portable values during first sync, let the user choose iCloud values or replace them with this Mac's portable values.
- After onboarding, resolve concurrent changes per portable field using modification timestamps; independent fields must not overwrite one another.
- Continue with local settings when iCloud is signed out, unavailable, over quota, or temporarily failing. Surface a non-blocking status and retain pending local changes.
- Disabling sync keeps current local values and does not erase cloud data. Account changes trigger a fresh merge decision instead of silently importing another account's values.
- Do not sync EventKit calendar contents, credentials, permissions, notifications, or local Shortcut names.

## Feature Priority

### Current release

1. Structured and advanced date/time formatting with live preview.
2. Unified ordered clocks, custom labels, drag reorder, and status-item scroll/trackpad carousel navigation.
3. Opt-in iCloud preference sync for entitlement-enabled builds.
4. Local-only compatibility for the GitHub build.

### Next candidates

1. Settings export/import as an explicit offline backup and migration path.
2. Configurable event horizon and event count in the popover.
3. Sync diagnostics with last-success time and manual retry.

### Later candidates

1. Working-hours overlap across selected world clocks.
2. Per-clock working-hour highlighting and day-boundary indicators.
3. Optional next-event countdown in the popover, not in the menu bar by default.
4. Universal-link based settings handoff if a companion product is introduced.

## Out of Scope

- Syncing EventKit calendar contents, credentials, authorization state, or Calendar notifications.
- Building a second calendar database.
- CloudKit records for the current small preference set; iCloud key-value storage is the appropriate mechanism.
- Silently erasing local or cloud settings during onboarding, disablement, sign-out, or account changes.

## Acceptance Criteria

- [ ] Existing installations retain the current visible menu-bar format until the user changes it.
- [ ] Every structured formatting combination renders a non-empty time segment and follows the local system locale.
- [ ] Advanced patterns update a live preview; invalid or empty time output cannot replace the active format; reset restores `EEE MMM d` and `HH:mm:ss`.
- [ ] Excessively wide output is warned about without crashing or silently truncating the saved pattern.
- [ ] Reordering time zones changes rotation/fallback order and survives restart.
- [ ] Custom city labels appear wherever that clock's title is shown, fall back when empty, and survive restart.
- [ ] Deliberate vertical scroll/trackpad gestures over the status item move one step through the wrapping clock order and enter manual mode.
- [ ] Timed rotation cannot override a gesture-selected clock; the existing `Auto Rotate` command explicitly resumes rotation.
- [ ] Portable settings round-trip through an injected iCloud key-value store and merge independently per field by timestamp.
- [ ] Entitlement-enabled builds offer opt-in onboarding, conflict choice, status, enable/disable, and account-change handling.
- [ ] Builds without the iCloud entitlement remain fully functional, local-only, and free of nonfunctional sync controls.
- [ ] iCloud failures never block local settings changes or erase pending values.
- [ ] Existing calendar, appearance, overview, Quick Actions, quick-event, launch-at-login, and clock-rotation behavior remains functional.
- [ ] This updated PRD plus `design.md` and `implement.md` are approved by the user's instruction to begin implementation.
