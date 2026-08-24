# Implementation plan

## Preconditions and contracts

- Keep all trackpad settings machine-local; do not add `PortableSettingField` cases.
- Keep the existing four `PopoverTab` cases unchanged.
- Use the model and data-flow contracts in `design.md`; do not create a second settings store or action catalog.
- Dynamic private symbols must be optional and fail closed. No build-time private-framework link.
- Preserve macOS 13 deployment compatibility and existing English/Simplified Chinese key parity.

## Ordered implementation

### 1. Persisted model and settings boundary

- Add generic Codable trigger, action, scope, modifier, point, rule, settings, and import-envelope types.
- Encode the two hold-tap rules, left-edge volume, and right-edge brightness as editable presets.
- Add `AppSettings.trackpadGestureSettings` with a default initializer value.
- Add `trackpadGestureSettings.v1` load/save in `SettingsStore`, normalizing bad neighbors independently.
- Add `AppModel` mutation helpers and apply the runtime settings after every relevant update.

Rollback point: removing the property/key and new model file leaves every existing stored key untouched.

### 2. Pure gesture engine

- Implement normalized frame/contact/session types.
- Implement deterministic scope/modifier rule resolution with specific-app precedence.
- Implement contact tap/double-tap/press, region, directional swipe, edge-entry swipe, pinch, tip-tap, selected-finger swipe, continuous edge, and drawing recognition.
- Make hold-tap commit on the lifted finger's completed tap exactly once while the opposite anchor remains stable.
- Quantize continuous edge deltas with hysteresis, direction inversion, sensitivity, cooldown, and rate cap.
- Reset per-device state on cancel, removal, wake, time reversal, and settings replacement.

Rollback point: the pure engine has no side effects and can be disconnected from the runtime service.

### 3. Raw provider and direct system controls

- Define and assert the 96-byte MultitouchSupport frame layout.
- Load required symbols with `dlopen`/`dlsym`; enumerate devices, keep the CF device list alive, register/unregister one callback, and start/stop with argument `0`.
- Copy callbacks into immutable frames and dispatch them to one serial engine queue.
- Reconcile supported devices without duplicate callbacks.
- Add public CoreAudio volume and dynamic DisplayServices brightness backends with settable checks, clamping, and read-back.

Rollback point: unsupported/private symbol failure leaves the service disabled and all settings editable.

### 4. Runtime service and action execution

- Add one long-lived `TrackpadGestureService` owned by `AppModel`.
- Resolve frontmost bundle ID and modifier flags at recognition time, then dispatch only the winning rule.
- Implement Quick Action/Shortcut reuse, keyboard/mouse synthesis, open target, AppleScript, window placement, pointer-window activation, and direct system-control actions.
- Publish bounded diagnostics and a feedback HUD; rate-limit haptics for continuous actions.
- Stop and clear runtime state when disabled, on termination, and around sleep/device changes.

### 5. Native settings pane

- Add `.trackpad` before `.quickActions` in Settings navigation and route it to `TrackpadSettingsView`.
- Implement runtime status, enablement, live contact preview, ordered rule management, inline editing, scope controls, trigger/action fields, drawing recorder, import/export, and reset presets.
- Keep advanced fields progressively disclosed and show action-specific permission/remediation before execution.
- Add matching English and Simplified Chinese localization entries and accessibility labels/help.

### 6. Clean Keyboard authorization recovery

- Return typed startup failures from `KeyboardEventBlocker`.
- Surface current Accessibility state and System Settings URL in the Quick Action availability/remediation path.
- Distinguish trust denial from event-tap creation failure; do not retry a suppressed prompt as if it could change state.

## Validation plan

1. Build the exact package target:
   - `swift build`
2. Run focused existing and new contract coverage for settings, gestures, permissions, navigation, localization, and runtime boundaries:
   - `swift test --filter Trackpad`
   - `swift test --filter QuickActionAuthorizationTests`
   - `swift test --filter SettingsInformationArchitectureTests`
   - `swift test --filter Localization`
3. Run the complete package suite once integration is stable:
   - `swift test`
4. Assemble the app through the existing package script, launch it with an isolated defaults domain when available, and inspect the Trackpad pane using computer-use.
5. On the built-in trackpad, verify provider/device activation and live contacts. Exercise the requested two hold-tap directions and left-edge volume/brightness rules; capture original volume/brightness and restore them after the smoke run.
6. Disable the module and verify callback/device status returns to disabled while ordinary pointer, scrolling, popover swipe navigation, and app startup remain unaffected.
7. Reopen Settings and relaunch the app to prove rule round-trip, then import/export a rule set and verify app-specific precedence.

## High-risk boundaries

- `MultitouchTrackpadSource.swift`: private ABI, C layout, callback lifetime, and hot-plug reconciliation.
- `TrackpadGestureEngine.swift`: duplicate emissions and false positives during ordinary scrolling.
- `TrackpadActionExecutor.swift`: permission scoping, AX window geometry, and system-setting read-back.
- `AppModel.swift` / `SettingsStore.swift`: local-only persistence and service reconfiguration.
- `StatusPopoverView.swift`: sidebar ordering without changing popover tabs.
- `QuickActionService.swift`: preserving current cleaning overlay behavior while making authorization failures truthful.

## Evidence used

- Local BetterAndBetter 2.7.7 `Preferences.strings` exposes 89 touch gesture menu entries and rule columns for application, enablement, modifier, gesture, action, cursor activation, and note.
- Local BetterAndBetter `SelectAction.strings` exposes Shortcut Keys, Preset, AppleScript, and Simulate Trackpad Gesture; its own warning limits simulated trackpad actions to the normal-mouse module.
- BetterAndBetter's public repository documents per-app/blacklist behavior, modifier and bottom-thumb drawing, presets/scripts/shortcuts, and rule import/export.
- This Mac successfully loaded the required MultitouchSupport and DisplayServices symbols, enumerated one built-in trackpad, read the current display brightness, and read the CoreAudio default-output volume property.
