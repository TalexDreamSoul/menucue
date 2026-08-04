## Scenario: Retained popover sampling and machine-local motion policy

### 1. Scope / Trigger

Use this pattern when a retained `NSPopover` owns live sampling or when a visual-quality preference changes SwiftUI/AppKit animation behavior without changing data freshness.

### 2. Signatures

- Authoritative presentation state: `@MainActor PopoverPresentationState.isPresented`
- Idempotent sampling gate: `StatusSamplingController.update(isVisible:isStatusSelected:)`
- Coherent metrics publication: `SystemMetricsService.frame: SystemMetricsDisplayFrame`
- Local setting: `AppSettings.animationQuality: AnimationQuality`
- Persistence key: `animationQuality.v1`
- Effective policy: `MotionProfile.resolve(quality:reduceMotion:)`

### 3. Contracts

- `NSPopover` retains its content after closing, so SwiftUI `onDisappear` is cleanup fallback only. Start and stop popover-scoped work from `PopoverPresentationState` plus the selected-tab state.
- Retain/release transitions must be idempotent. Closing the popover or leaving Status releases metrics exactly once and clears hover-detail state; reopening reacquires exactly once.
- A released sampling generation may finish utility work, but it must not publish stale data or schedule a follow-up sample.
- Publish each successful metrics sample as one coherent frame containing the snapshot and matching CPU history. Derived consumers subscribe to the frame rather than independent snapshot/history publications.
- Animation quality is machine-local. Persist it through `SettingsStore`, default unknown or corrupt values to `.elegant`, and keep it out of `PortableSettingField`.
- Resolve animation categories through one `MotionProfile` environment value. macOS Reduce Motion overrides the stored quality, including AppKit `CATransition` and continuous `TimelineView` behavior.
- Animation quality controls presentation only. It must never change metrics intervals, probe cadence, or value freshness.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Popover closes while Status remains in the retained hierarchy | Release once; clear hover target; start no later sample |
| Status is selected while the popover is hidden | Keep sampling inactive |
| Delayed worker result arrives after release | Reject publication and follow-up work |
| History has reached capacity | Publish one complete frame per successful sample |
| Stored animation raw value is missing or unknown | Resolve to Elegant; preserve neighboring settings |
| Reduce Motion turns on while Full is selected | Disable spatial, numeric, symbol, spring/scale, and continuous motion immediately |
| Minimal profile shows indeterminate work | Use a static status symbol; do not start an indeterminate animation |

### 5. Good / Base / Bad Cases

- Good: `StatusSamplingController` combines authoritative visibility and tab selection, while views consume one injected `MotionProfile`.
- Base: the default Elegant profile keeps concise primary feedback and the configured sampling interval unchanged.
- Bad: relying only on `onDisappear`, publishing snapshot and history separately, or globally disabling SwiftUI transactions.

### 6. Tests Required

- Repeated visible/hidden and tab-selection transitions assert balanced retain/release counts.
- Closing before priming or timer callbacks asserts no new probe begins; delayed results assert no publication.
- Successful samples, including saturated history, assert exactly one frame publication.
- Missing, corrupt, and unknown animation values assert Elegant fallback and local-only persistence.
- Every preset and Reduce Motion assert category decisions, continuous cadence, and status-clock transition behavior.
- Segmented-control tests assert accessibility label/help and two-way binding updates.
- Source audit asserts no direct animation, numeric transition, symbol effect, matched geometry, continuous timeline, or `CATransition` bypasses policy.

### 7. Wrong vs Correct

```swift
// Wrong: retained popover content may never disappear, and two publications
// invalidate the same observed tree twice.
.onAppear { metrics.retain() }
.onDisappear { metrics.release() }
metrics.snapshot = snapshot
metrics.cpuHistory = history

// Correct: presentation state drives one guarded lifecycle and one frame commit.
sampling.update(isVisible: presentation.isPresented, isStatusSelected: isStatusSelected)
metrics.frame = SystemMetricsDisplayFrame(snapshot: snapshot, cpuHistory: history)
```

```swift
// Wrong: visual quality changes the data product or bypasses accessibility.
metrics.setInterval(quality == .minimal ? 10 : 1.5)
withAnimation(.spring()) { selection = next }

// Correct: sampling stays independent and motion resolves semantically.
let motion = MotionProfile.resolve(quality: settings.animationQuality, reduceMotion: reduceMotion)
withAnimation(motion.navigationAnimation) { selection = next }
```

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

## Scenario: Ordered popover tabs and swipe delivery

### 1. Scope / Trigger

Use this pattern when the popover tab order is configurable or an AppKit gesture container publishes navigation into SwiftUI.

### 2. Signatures

- Stable identity: `PopoverTab.rawValue`
- Ordered setting: `AppSettings.popoverTabOrder`
- Local key: `popoverTabOrder.v1`
- Mutation boundary: `AppModel.movePopoverTabs(fromOffsets:toOffset:)`
- Navigation: `PopoverTab.moving(by:in:)`
- Event bridge: `SwipeForwardingController(rootView:relay:)`

### 3. Contracts

- The product default is Status, Calendar, Power, Actions.
- Persist raw IDs locally; this field is not part of `PortableSettingField` or iCloud sync.
- Keep the first occurrence of each known stored ID, ignore unknown IDs individually, then append every missing built-in tab in product-default order.
- The tab bar, click animation direction, arrow keys, horizontal wheel input, and trackpad swipe all consume `AppSettings.popoverTabOrder`.
- The configured first tab initializes the first popover view after launch. Retained SwiftUI state preserves the last selected tab across later popover presentations in that app session.
- The AppKit container and observing SwiftUI view must receive the same `SwipeRelay` instance. Never create an unconnected relay inside the container.
- Horizontal handling must not opt into or consume vertical-dominant scrolling.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Preference missing | Use Status, Calendar, Power, Actions |
| Empty, duplicate, or unknown IDs | Normalize to every known tab exactly once |
| New built-in tab after upgrade | Append it after valid stored entries |
| Movement crosses either end | Wrap in the configured order |
| Repeated same-direction gestures | Publish each with a distinct sequence |
| AppKit and SwiftUI receive different relays | Invalid wiring; no tab update is observable |
| Vertical-dominant gesture | Pass through to the nested scroll view |

### 5. Good / Base / Bad Cases

- Good: create one `SwipeRelay`, pass it to both `StatusPopoverView` and `SwipeForwardingController`, and observe one tab update per recognized gesture.
- Base: no stored preference resolves to the product default; opening the popover a second time retains the current session selection.
- Bad: the container constructs its own relay while SwiftUI observes another instance; logs show `navigate(1)` but no `TAB old -> new` transition.

### 6. Tests Required

- Missing, empty, duplicate, unknown, reordered, and round-tripped preferences assert the complete ordered array.
- Forward and backward movement assert configured-order wraparound.
- Container tests assert `controller.relay === container.relay === injectedRelay`.
- Recognizer tests assert one navigation per gesture, repeated gesture delivery, and vertical pass-through.
- Real-trackpad acceptance with `MENUCUE_SWIPE_LOG=1` must show both `accumulator -> navigate(...)` and the corresponding `TAB old -> new` line.

### 7. Wrong vs Correct

```swift
// Wrong: gesture events and SwiftUI updates travel through different objects.
let relay = SwipeRelay()
let controller = SwipeForwardingController(rootView: Content(swipeRelay: relay))
// SwipeForwardingView silently owns another SwipeRelay.

// Correct: one relay crosses the AppKit/SwiftUI boundary.
let relay = SwipeRelay()
let controller = SwipeForwardingController(
  rootView: Content(swipeRelay: relay),
  relay: relay
)
```

## Scenario: Display-bound cleaning overlays

### Scope / Trigger

Use this pattern for full-screen runtime UI that must cover every connected display and remain correct while displays are connected, disconnected, rearranged, or resized.

### Signatures

- Display identity and geometry: `CleaningDisplaySnapshot(id:frame:screen:)`
- Runtime reconciliation owner: `CleaningDisplayOverlayCoordinator.start()`, `stop()`
- Topology event: `NSApplication.didChangeScreenParametersNotification`

### Contracts

- Derive stable display identity from `NSScreenNumber`; do not key overlays by array position or frame.
- `NSWindow(contentRect:..., screen: targetScreen)` consumes a rectangle in the target screen's local coordinate space. Initial full-screen content must use origin `.zero` and the target frame's size. Passing `NSScreen.frame` here double-applies any non-zero display origin.
- `NSWindow.setFrame` consumes global virtual-desktop coordinates. Topology updates must continue applying the snapshot's full global frame.
- AppKit screen discovery, window construction, and presentation run on the main queue; window factories should assert this boundary.
- Keep exactly one overlay per current display ID. Reuse and resize retained overlays, remove missing IDs, and create newly observed IDs.
- A topology refresh only reconciles overlays. It must not restart the cleaning countdown, input monitor, keyboard blocker, or published cleaning state.
- Every overlay renders the same shared `CleaningModeController`, so countdown and exit behavior stay consistent across displays.
- `stop()` removes both all overlays and the display-change observer. Never leave topology observers active outside cleaning mode.

### Validation Matrix

| Condition | Required behavior |
|---|---|
| Second display present at start | Create one correctly framed overlay per display using a screen-local initial content rect |
| AirPlay/Sidecar display has non-zero global origin | Initial window frame resolves to that display's exact global frame and screen ID |
| Display added | Create only the new display's overlay |
| Display resized or rearranged | Update the retained overlay frame in global screen coordinates |
| Display removed | Order out and release only that display's overlay |
| Cleaning mode stops | Remove all overlays and ignore later topology notifications |

### Tests Required

- Initial multi-display snapshots create one overlay per stable ID.
- A non-zero display frame produces an initial content rect with origin `.zero` and matching size.
- When a non-primary display is connected, an unpresented production window reports that display's exact frame and `NSScreenNumber`; skip only when no non-primary display exists.
- Window tests preserve screen-saver level, all-Spaces/full-screen/stationary behavior, opaque black background, and lifecycle attributes without presenting the black overlay.
- A topology notification removes stale overlays, reuses and resizes retained overlays, and creates added overlays.
- After `stop()`, posting another topology notification has no effect.

### Wrong vs Correct

```swift
// Wrong: `screen:` treats this global origin as local and adds the screen origin again.
NSWindow(
  contentRect: targetScreen.frame,
  styleMask: [.borderless],
  backing: .buffered,
  defer: false,
  screen: targetScreen
)

// Correct: initial construction is screen-local; later `setFrame` updates are global.
let localContentRect = NSRect(origin: .zero, size: targetScreen.frame.size)
let window = NSWindow(
  contentRect: localContentRect,
  styleMask: [.borderless],
  backing: .buffered,
  defer: false,
  screen: targetScreen
)
window.setFrame(targetScreen.frame, display: true)
```

```swift
// Wrong: becomes stale as soon as the display topology changes.
let windows = NSScreen.screens.map(makeOverlay)

// Correct: observe topology changes and reconcile by NSScreenNumber.
displayOverlays.start()
// ... later ...
displayOverlays.stop()
```

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

## Scenario: Explicit process-health diagnostics

### Contracts

- `ProcessHealthService.analyze()` is the only scan trigger. It runs one bounded `ps -M` probe on a utility queue; no timer, startup hook, persistence, or iCloud field may enumerate processes or threads.
- `ProcessHealthParser` groups one row per thread by PID, preserving process state and command text. A state starting with `Z` remains a visible zombie; it is never inferred from process age or CPU use.
- The Power popover exposes separate, explicit actions for analysis and `NSWorkspace` launch of Activity Monitor. Neither action changes a process or escalates privileges.
- A successful tab transition and a user-driven arrival at the bottom of scrollable popover content issue one alignment haptic. Initial layout and content that does not overflow must not issue feedback.

### Tests Required

- Parser fixtures cover repeated thread rows, commands with spaces, Z-prefixed state, totals, and deterministic CPU/thread ordering.
- An injected probe proves an explicit `analyze()` request publishes its result without relying on a live process inventory.
