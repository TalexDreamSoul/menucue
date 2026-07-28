# Implementation plan: clock customization and time-zone organization

## Scope guard

Implement the full current-release requirements in `prd.md`: clock customization, ordered clocks, status-item carousel navigation, local migration, and production-capable opt-in iCloud key-value preference sync. Keep builds without the iCloud entitlement fully local-only.

## Ordered implementation

### 1. Replace the clock-selection model

Files:

- `Sources/TouchMacer/AppModels.swift`
- `Sources/TouchMacer/SettingsStore.swift`
- `Sources/TouchMacer/AppModel.swift`

Work:

1. Add the unified ordered clock-entry type with stable system identity and optional custom label.
2. Replace `showsSystemTimeZone` and `selectedTimeZoneIDs` in active settings with the non-empty ordered collection.
3. Resolve `clockTimeZones`, fallback, and rotation from that order.
4. Add explicit model operations for add, remove/hide, re-add system, move, and label update.
5. Enforce uniqueness, valid IANA identifiers, trimmed labels, and the non-empty invariant at the model boundary.
6. Remove obsolete active-model fields and call sites; retain legacy key reads only for migration.

Rollback point: the old clock-selection representation remains recoverable from the previous revision until migration persistence is proven.

### 2. Add local persistence and migration

File:

- `Sources/TouchMacer/SettingsStore.swift`

Work:

1. Add keys for ordered identities and custom labels.
2. Load the new representation when present.
3. Otherwise migrate the current system visibility plus custom identifier order without visible change.
4. Fall back to the system entry if stored data is invalid or empty.
5. Save only the new representation; stop writing superseded selection keys.
6. Keep unrelated calendar, appearance, overview, and rotation settings unchanged.

Focused smoke check:

- launch with existing defaults and confirm the same first clock and rotation order
- reorder, relaunch, and confirm persistence
- hide/re-add/move the system entry and confirm fallback follows the first visible row

Do not proceed to formatting until migration and ordering behavior work end to end.

### 3. Add the menu-bar format model and renderer

Files:

- `Sources/TouchMacer/AppModels.swift`
- `Sources/TouchMacer/SettingsStore.swift`
- a focused formatter file under `Sources/TouchMacer/` if keeping this logic in `AppModels.swift` would mix responsibilities

Work:

1. Add structured/advanced mode and the semantic format enums from `design.md`.
2. Define the compatibility default matching `EEE MMM d` plus `HH:mm:ss`.
3. Implement locale-aware structured pattern generation.
4. Implement separate advanced date/time rendering and validation.
5. Reuse formatter instances across ticks; rebuild only when settings or locale changes.
6. Add a width-measurement result for preview warnings without making width a save blocker.

Focused smoke check:

- render the compatibility default at a fixed date/time zone
- switch 12/24-hour, seconds, date, weekday, and segment order
- verify invalid/empty time drafts do not replace the active format
- verify reset returns to the compatibility default

### 4. Integrate status-item rendering

File:

- `Sources/TouchMacer/StatusBarController.swift`

Work:

1. Replace hard-coded controller formatters with the shared renderer.
2. Render date and time segments in the configured order while preserving the date capsule.
3. Reconfigure renderer state when published settings change.
4. Add a status-item-local scroll-wheel monitor with deliberate-delta threshold, previous/next wrapping, and momentum cooldown.
5. Route gesture selection through `manualStatusClockID` so timer ticks refresh time without advancing the clock.
6. Keep the existing `Auto Rotate` action as the explicit way to leave manual mode and remove the event monitor during teardown.
7. Preserve clock-switch animation, quick clock selection, appearance refresh, and time-zone rotation.
8. Use custom resolved titles wherever the controller shows a clock title.
Focused smoke check:

- exercise every segment order with date visible and hidden
- rotate across multiple clocks and manually select a clock
- scroll up/down over the status item and confirm one-step wrapping, manual precedence, and `Auto Rotate` restoration
- confirm scrolling elsewhere is unaffected and trackpad momentum does not skip uncontrollably
- confirm the capsule, animation, flag behavior, and system appearance still update
### 5. Build the settings controls

File:

- `Sources/TouchMacer/StatusPopoverView.swift`

Work:

1. Add a Menu Bar format group with structured/advanced controls and reset.
2. Keep advanced text in draft state until valid.
3. Add live preview plus inline validation and width warning.
4. Replace the custom-only list with a reorderable list containing system and custom entries.
5. Add editable custom labels, append-new-clock behavior, system re-add control, and invariant-aware remove/hide actions.
6. Ensure clock cards, quick-selection menu, and settings rows resolve the same custom title.

Focused smoke check using the built app bundle:

- modify each control and observe the status item immediately
- drag system and custom entries to several positions
- edit and clear a custom label
- relaunch and confirm all values persist
- confirm the final visible clock cannot be removed
- confirm calendar, quick-event, appearance, and update-check surfaces still open and behave as before

### 6. Add iCloud preference synchronization

Files:

- `Sources/TouchMacer/PreferenceSyncService.swift`
- `Sources/TouchMacer/AppModels.swift`
- `Sources/TouchMacer/SettingsStore.swift`
- `Sources/TouchMacer/AppModel.swift`
- `Sources/TouchMacer/TouchMacerMain.swift`
- `Sources/TouchMacer/StatusPopoverView.swift`
- `Resources/TouchMacer.entitlements`
- `scripts/build-app.sh`

Work:

1. Add a typed portable-settings projection and per-field modification metadata.
2. Add an injectable iCloud key-value-store boundary with production and in-memory implementations.
3. Store independent timestamped envelopes per portable field and merge only newer fields.
4. Observe external, initial-sync, quota, server, and account-change notifications.
5. Keep local persistence authoritative and prevent cloud imports from echoing as fresh local edits.
6. Add entitlement/account availability, sync status, onboarding, conflict choice, enable/disable, and manual retry state to `AppModel`.
7. Show sync controls only when the app carries the iCloud key-value entitlement.
8. Add an app entitlement template and a configurable signed-build path while preserving the existing ad-hoc local-only build.

Focused smoke check:

- local settings continue to work without an entitlement
- in-memory cloud changes propagate through the model in both directions
- independent fields merge by timestamp and stale fields are ignored
- disablement keeps local/cloud values intact
- account changes require a new merge decision

### 7. Cleanup after the feature works

Only after the focused app smoke check passes:

1. Delegate high-signal test authoring for formatter contracts, migration, persistence, ordering, fallback, labels, carousel state, portable projections, and sync merging.
2. Remove superseded model code, dead keys from writes, and duplicate formatter helpers.
3. Update user-facing feature text to describe configurable formatting, ordering, labels, carousel gestures, local persistence, and entitlement-gated iCloud sync.
4. Run the project formatter only if the repository already defines one.

## Validation commands

Run focused checks in this order after implementation:

```bash
swift build
swift test --filter TouchMacerTests
./scripts/build-app.sh
open .build/app/TouchMacer.app
```

The interactive app-bundle smoke test is required because menu-bar layout, drag behavior, attributed-string styling, gesture hit testing, sync-control gating, and restart persistence are not proven by unit tests alone. Two-device iCloud propagation additionally requires a provisioned entitlement-enabled build and cannot be claimed from an ad-hoc bundle.

## Review gates

- The new ordered model has no dual-write path and migration preserves current visible order.
- No operation can leave the app without a visible clock.
- Formatting defaults preserve the current display for existing users.
- Advanced drafts cannot corrupt the active saved format.
- Per-tick rendering does not allocate `DateFormatter` instances.
- Custom labels never replace the IANA identifier used for calculations.
- Status-item gestures wrap predictably, enter manual mode, and do not steal scrolling outside the item.
- Timed rotation cannot override manual selection; `Auto Rotate` restores interval rotation.
- Portable fields have one shared projection and merge owner; device-local fields never enter iCloud.
- Cloud imports do not echo as newer local writes, and independent fields merge by timestamp.
- Builds without the entitlement remain local-only and hide sync controls.
- Local settings remain writable during iCloud sign-out, quota, account-change, and transient failure states.
- All current-release acceptance criteria in `prd.md` have direct verification evidence.
