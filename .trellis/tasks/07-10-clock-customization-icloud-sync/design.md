# Design: clock customization and time-zone organization

## Scope

This design covers two distribution capabilities from one codebase:

- all builds: structured and advanced menu-bar formatting, live preview and validation, one ordered clock list, drag reorder, custom labels, and scroll/trackpad carousel navigation
- all builds: local persistence and migration, with manual carousel selection taking precedence over timed rotation until the user resumes `Auto Rotate`
- entitlement-enabled App Store/TestFlight builds: opt-in iCloud key-value preference sync
- ad-hoc GitHub builds: unchanged local-only behavior with no nonfunctional sync control

CloudKit records are intentionally excluded because the portable preference set has key-value semantics and remains far below the iCloud key-value store quota.

## Model

### Menu-bar format

Add a value object to `AppSettings` that owns the complete formatting decision instead of scattering individual flags through the controller:

- mode: structured or advanced
- clock cycle: system, 12-hour, or 24-hour
- shows seconds
- date style: hidden, system short, abbreviated, or ISO
- weekday style: hidden, short, or full
- segment order: date then time, or time then date
- advanced date pattern
- advanced time pattern

The default value reproduces the current display: `EEE MMM d` and `HH:mm:ss`, with date before time. Locale is not persisted; rendering always uses `Locale.autoupdatingCurrent`.

### Ordered clocks

Replace the split `showsSystemTimeZone` plus `selectedTimeZoneIDs` representation in `AppSettings` with one non-empty ordered collection of clock entries:

- a stable system entry whose identity remains `system` while its effective `TimeZone` follows `TimeZone.autoupdatingCurrent`
- custom entries identified by their IANA time-zone identifier
- an optional trimmed custom label on each entry

Invariants:

- entry identities are unique
- invalid custom identifiers are discarded during load
- the collection is never empty
- the system entry may appear at any position or be absent
- removing the final visible entry is rejected
- order is the single source of truth for automatic rotation and fallback
- an empty or whitespace-only custom label falls back to `TimeZoneCatalog.shortTitle`

`ClockTimeZone` remains a resolved display model. `AppSettings.clockTimeZones` resolves ordered persisted entries into live system/custom clocks and applies custom labels consistently.

### Portable settings

Define a typed `PortableSettings` projection rather than serializing all of `AppSettings`. Each portable field is independently versioned with a modification timestamp and device origin so unrelated concurrent changes merge without replacing the whole settings bundle.

Portable fields:

- menu-bar format
- ordered clock entries and custom labels
- status-bar rotation interval
- overview time-zone identifier
- calendar week-start day
- in-app appearance mode

Calendar selection, system appearance mutation, pinned Quick Actions, iCloud enablement/onboarding state, manual carousel selection, and runtime state never enter this projection.

## Formatting boundary

Introduce a focused formatter component rather than continuing to mutate hard-coded `DateFormatter` instances inside `StatusBarController`.

Inputs:

- menu-bar format settings
- resolved clock/time zone
- date
- locale, injectable for deterministic tests and defaulting to `autoupdatingCurrent`

Output:

- optional date segment text
- required time segment text
- segment order
- validation state

Structured mode derives locale-aware date/time patterns from the selected semantic controls. Forced 12/24-hour modes override only the clock cycle; system mode respects the local preference. Advanced mode applies the two user patterns directly.

Validation rules:

- the time pattern and rendered time must be non-empty
- a visible date pattern must render non-empty
- invalid drafts never replace the last valid active settings
- width is advisory: preview reports excessive width but saving remains allowed
- reset restores the compatibility default

Keep formatter instances alive and rebuild them only when formatting settings or locale changes. Per-tick rendering must not allocate new formatter objects.

## UI

Extend the existing Menu Bar settings pane rather than adding another sidebar destination.

### Format group

- structured/advanced mode control
- structured controls listed in the PRD
- separate advanced date/time pattern fields
- date/time order control
- live preview using the first configured clock and current date
- inline validation or width warning
- reset button

Draft advanced text remains view-local until it passes validation. Valid changes flow through `AppModel.updateSettings`, preserving the existing immediate-persistence behavior.

### Clock list

Replace the current custom-time-zone-only stack with a reorderable list of all visible clock entries.

Each row contains:

- drag handle and current position
- system/custom identity and time-zone subtitle
- editable optional city label
- remove/hide action, disabled when it would violate the non-empty invariant

The existing add picker appends a custom entry. The system clock can be re-added through an explicit control when absent.

### Status-item carousel interaction

Install one local scroll-wheel event monitor owned by `StatusBarController`. Handle an event only when its window/location hits the status-item button; pass all other events through unchanged.

Accumulate dominant vertical deltas until a deliberate threshold is crossed, map upward and downward movement to previous and next entries, wrap at both ends, then clear the accumulator and enforce a short cooldown that absorbs trackpad momentum. The chosen clock is stored only in controller runtime state as `manualStatusClockID`.

`currentStatusClock(at:)` already gives manual selection precedence. Timer ticks continue refreshing the displayed seconds but cannot advance the selected clock while manual mode is active. The context-menu `Auto Rotate` action clears `manualStatusClockID` and resumes interval-based rotation. The event monitor is removed during controller teardown.

## Data flow

1. `SettingsStore.load()` reads the normalized local settings and legacy keys when migration is required.
2. `AppModel` remains the only general settings mutation boundary and persists every accepted change locally first.
3. The model records modification metadata only for portable fields changed by the user, then asks `PreferenceSyncService` to export those fields when sync is enabled.
4. `PreferenceSyncService` stores one timestamped envelope per portable field in `NSUbiquitousKeyValueStore`, preventing unrelated fields from overwriting one another.
5. External iCloud notifications are decoded and merged per field. Newer cloud fields flow back through one explicit `AppModel` import method that saves locally without echoing them as new user edits.
6. First-sync conflicts and account changes pause automatic imports until the user chooses cloud or local values.
7. `StatusBarController` resolves manual carousel selection before interval rotation, rebuilds formatter configuration when settings change, and renders the ordered segments on each tick.
8. Popover clock cards, quick-selection menu, settings rows, and sync UI consume the same resolved models and published state.

## Persistence and migration

Local `UserDefaults` remains the durable source available on every build. Persist property-list-compatible settings values plus device-local sync metadata:

- formatting enum raw values, booleans, and advanced pattern strings
- ordered clock identities and custom labels
- modification timestamps for each portable field
- sync enabled/onboarding/account-decision state

Clock migration is read-once by key presence:

- if the new order key exists, it is authoritative
- otherwise, prepend the enabled system entry and append the existing custom identifier order
- if migration produces no valid entries, insert the system entry
- save only the new representation after the first subsequent settings write; do not keep dual-write compatibility fields

iCloud stores one encoded property-list/JSON `Data` envelope per portable field under a versioned key namespace. Each envelope contains schema version, modification time, origin identifier, and typed payload. Unknown future fields are ignored; undecodable fields do not invalidate valid neighbors. Manual carousel position is intentionally transient and never persisted or synced.

## Compatibility and risk

- Existing users see no format or ordering change after upgrade.
- System time-zone movement uses stable identity, so travel does not corrupt order or labels.
- Custom labels affect display only; calculations retain IANA identifiers.
- Scroll handling is scoped to the status-item hit region and consumes no unrelated application scrolling.
- Threshold and cooldown logic prevents high-resolution trackpad momentum from skipping multiple clocks unintentionally.
- Invalid stored enum values, clock entries, cloud envelopes, or patterns normalize independently to safe local values.
- The iCloud service verifies the key-value entitlement before exposing sync controls. Ad-hoc GitHub builds never pretend to sync.
- Local writes succeed even when iCloud is signed out or unavailable; cloud export is best-effort and retryable.
- Account changes never auto-import another account's settings over the current Mac.
- Notification handling and model imports run on the main actor to keep published settings deterministic.

## iCloud service boundary

`PreferenceSyncService` owns `NSUbiquitousKeyValueStore`, entitlement/account availability, external-change observation, encoding, quota/account-change status, and pending first-merge decisions. It does not own `AppSettings` and cannot write `UserDefaults` directly.

The service is injected behind a small key-value-store protocol for deterministic tests. Production uses `.default`; tests use an in-memory implementation and explicit external-change events.

## Verification strategy

Behavioral tests cover:

- every structured pattern combination and deterministic locale output
- advanced-pattern validation and reset
- legacy migration to the ordered clock model
- round-trip persistence of format, order, labels, sync metadata, and portable projections
- system entry at non-first positions, rotation/fallback, and the non-empty invariant
- carousel wrap direction, manual precedence, auto-rotate restoration, threshold, and cooldown behavior
- independent per-field iCloud merge, stale-value rejection, first-sync choices, disablement, account changes, malformed data, and quota/error states
- absence of sync UI and continued local behavior when the entitlement is unavailable

A focused app-bundle smoke test covers live preview, status-item rendering, scroll/trackpad carousel navigation, drag reorder, restart persistence, locale-sensitive output, unchanged calendar/appearance behavior, and local-only operation. A provisioned entitlement-enabled build additionally verifies two-device propagation, offline edits, conflict resolution, sign-out, and account change.
