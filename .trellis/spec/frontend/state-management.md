# State Management

## Scenario: Persisted settings with authoritative macOS runtime state

### 1. Scope / Trigger

Use this pattern when a feature has both user configuration and state owned by macOS or another system service. Quick Actions is the reference implementation.

### 2. Signatures

- Persisted configuration owner: `AppSettings`
- Persistence boundary: `SettingsStore.load() -> AppSettings`, `SettingsStore.save(_:)`
- Mutation boundary: `AppModel.updateSettings(_:)`
- Runtime owner: `QuickActionService: ObservableObject`
- Persisted action identity: `QuickActionReference.storageValue`

### 3. Contracts

- Views never read or write `UserDefaults` directly.
- `AppSettings` stores ordered user intent, such as pinned action references.
- Runtime state such as current Dark Mode, Dock auto-hide, availability, progress, and errors stays in the owning service.
- A state-changing action must request the change, re-read the system state, and publish the observed result.
- Persisted quick-action references use stable prefixes:
  - `builtin:<stable-id>`
  - `shortcut:<exact Apple Shortcut name>`
- Unknown references are ignored individually; valid neighboring references survive.
- Pinning is unique and capped at seven.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing setting key | Load product defaults |
| Stored empty array | Preserve the user's empty selection |
| Duplicate reference | Keep the first occurrence |
| Unknown built-in ID | Ignore that entry only |
| Missing renamed Shortcut | Keep a visible unavailable reference until the user removes it |
| System mutation denied | Publish failure and retain observed state |
| Runtime service unavailable | Keep persisted settings intact |

### 5. Good / Base / Bad Cases

- Good: Settings stores `.builtIn(.darkMode)` while `QuickActionService` queries the real system appearance.
- Base: User pins zero actions; the stored array remains empty and the UI shows only More.
- Bad: A toggle writes `true` to `UserDefaults` and assumes macOS accepted the requested system mutation.

### 6. Tests Required

- Empty defaults load product defaults.
- Explicit empty selection round-trips as empty.
- Mixed built-in/Shortcut ordering round-trips unchanged.
- Duplicate, unknown, and over-limit persisted values normalize independently.
- Failed runtime mutation does not change persisted configuration or report a false active state.
- View-level smoke tests verify settings mutations are immediately reflected by the popover.

### 7. Wrong vs Correct

#### Wrong

```swift
UserDefaults.standard.set(true, forKey: "darkModeEnabled")
isDarkModeEnabled = true
```

#### Correct

```swift
appearanceService.setSystemDarkMode(target)
quickActionService.refreshAll() // publishes the observed macOS state
```

## Project Rule

`AppModel` is the only general settings mutation boundary. Feature services may own runtime state and side effects, but they do not mutate persisted settings. SwiftUI views compose `@ObservedObject` owners and send intents through model/service methods.

## Scenario: Entitlement-gated iCloud preference synchronization

### 1. Scope / Trigger

Use this pattern when portable `AppSettings` fields synchronize through `NSUbiquitousKeyValueStore` while the same binary must remain fully functional without the iCloud entitlement.

### 2. Signatures

- Portable projection: `AppSettings.portableValue(for:) -> PortableSettingValue`
- Cloud import: `AppSettings.applyPortableValue(_:for:) -> Bool`
- Local mutation: `AppModel.updateSettings(_:)`
- Cloud-only import boundary: `AppModel.importPortableEnvelopes(_:force:)`
- Cloud payload: `PortableSettingEnvelope(field:modifiedAt:originDeviceID:value:)`
- Runtime owner: `PreferenceSyncService`

### 3. Contracts

- `SettingsStore` remains authoritative local persistence on every build.
- The service never reads or writes `UserDefaults`; it receives typed envelopes from `AppModel`.
- Each portable field uses a separate versioned iCloud key and timestamped envelope. Never upload one monolithic `AppSettings` blob.
- Portable fields are menu-bar format, ordered clocks/labels, rotation interval, overview time zone, week start, and in-app appearance.
- Calendar authorization/selection, system appearance mutation, Quick Actions, onboarding choices, account identity, and runtime state remain device-local.
- Local mutations save first, record timestamps for changed portable fields only, then publish to iCloud when enabled.
- Cloud imports save locally without being re-stamped or echoed as new local edits.
- Runtime entitlement detection gates both synchronization and UI visibility; ad-hoc builds remain local-only.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing iCloud entitlement | Status is unavailable; hide sync pane; local settings continue |
| Signed out / missing identity token | Keep local values; show retryable signed-out status |
| Malformed or future cloud field | Ignore that field only; merge valid neighbors |
| Remote timestamp is stale | Keep the newer local field |
| Initial local and cloud values both exist | Require explicit iCloud-versus-this-Mac choice |
| Account identity changes | Suspend imports and require a new source choice |
| Quota or synchronize failure | Publish non-blocking failure; never roll back local writes |
| Sync disabled | Preserve local and cloud values; stop uploads |

### 5. Good / Base / Bad Cases

- Good: changing only week start publishes one `calendarWeekStartDay` envelope and leaves clock order untouched.
- Base: an ad-hoc GitHub build loads, saves, and renders every setting with no sync UI.
- Bad: serializing all of `AppSettings` into one iCloud key lets a calendar-selection change overwrite an unrelated clock order and leaks device-local state.

### 6. Tests Required

- Entitlement-unavailable builds stay local-only.
- Initial onboarding supports disabled, local-upload, and explicit cloud-import paths.
- Independent fields use independent cloud keys and timestamps.
- Newer cloud values import; stale cloud values do not replace local values.
- Disablement preserves cloud data and prevents later uploads.
- Quota, synchronize failure, and account changes map to retry/decision states.
- Legacy local settings migrate before becoming portable values.

### 7. Wrong vs Correct

#### Wrong

```swift
cloudStore.set(try encoder.encode(settings), forKey: "all-settings")
settings = try decoder.decode(AppSettings.self, from: cloudData)
```

#### Correct

```swift
let envelope = PortableSettingEnvelope(
    field: .clockEntries,
    modifiedAt: modificationDate,
    originDeviceID: settings.syncDeviceID,
    value: settings.portableValue(for: .clockEntries)
)
preferenceSyncService.publishLocalChanges([envelope])
```

## Scenario: Status-item clock carousel runtime state

### Signatures

- Runtime state: `StatusClockSelectionState`
- Gesture transition: `selectTemporarily(clockID:at:duration:)`
- Context-menu transitions: `selectPersistently(clockID:)`, `resumeAutomaticRotation()`
- Availability cleanup: `removeUnavailableClockIDs(validClockIDs:)`
- Resolution boundary: `StatusClockResolver.clock(in:manualClockID:temporarySelection:at:)`

### Contracts

- `StatusItemInteractionView` owns status-item mouse and scroll routing; do not use an app-wide scroll event monitor.
- Vertical wheel/trackpad input advances one entry through `ClockCarouselNavigator` and wraps at both ends.
- A successful gesture replaces `clockSelection.temporarySelection`, restarting a complete configured rotation interval from that gesture time.
- While active, `TemporaryClockSelection` takes precedence over context-menu selection and timed rotation.
- When the temporary interval expires in automatic mode, rotation advances to the next configured clock and remains anchored to the gesture-selected clock for later intervals. Do not fall back to the absolute rotation timeline because it can leave the same clock visible for another interval.
- `clockSelection.persistentClockID` is set only by context-menu clock selection and remains selected until **Auto Rotate** is chosen.
- If a gesture occurs while a persistent context-menu selection exists, the gesture is shown temporarily and the persistent selection resumes when the temporary interval expires.
- Both values in `StatusClockSelectionState` are controller runtime state. They are never persisted or synchronized.
- A temporary interval captures the configured duration when the gesture occurs; after it expires, subsequent automatic intervals use the latest configured duration.
- Selecting a context-menu clock or **Auto Rotate** clears the temporary gesture state so the requested menu action takes effect immediately.
- Removed clock IDs are ignored and cleared without blocking the remaining fallback behavior.
- Precise gestures use a threshold and momentum suppression; wheel input uses a short cooldown.

### Tests Required

- Interaction view forwards scroll exactly once and routes primary/control/right clicks correctly.
- Carousel navigation wraps in both directions.
- A temporary gesture selection remains active immediately before its expiration boundary.
- At the expiration boundary, automatic mode advances from the gesture-selected clock to the next ordered clock and continues at the configured interval.
- A persistent context-menu selection survives across automatic rotation intervals.
- A temporary gesture selection overrides a persistent selection only until expiration.
- Unavailable persistent and temporary clock IDs are cleared together.
- An active temporary interval keeps its captured duration; automatic intervals after expiration use the latest configured duration.
- Clearing persistent selection restores automatic rotation.
