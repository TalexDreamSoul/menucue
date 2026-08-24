# Trackpad gesture automation

## Goal

Add a machine-local Trackpad module that turns raw multi-touch input into configurable actions without making Accessibility permission a prerequisite for touch observation or built-in volume and brightness control. Match the behavior and configuration breadth visibly available in BetterAndBetter's trackpad surface while using original code, assets, naming, and visual design.

## Background

- The current Clean Keyboard action gates its global keyboard event tap on Accessibility trust and only returns a generic retry message when macOS does not grant access.
- MenuCue already centralizes persisted intent in `AppSettings` / `SettingsStore`, runtime side effects in feature services, and mutations in `AppModel`.
- The app targets macOS 13+ and distributes outside the Mac App Store with Developer ID signing and notarization.
- The user explicitly requested implementation now, including parallel research of the locally installed BetterAndBetter app.

## Requirements

### R1. Permission-safe runtime

- Add a dedicated Trackpad settings pane and runtime service.
- Raw touch capture must start only after the user enables the module and stop promptly when disabled or the service is torn down.
- Raw capture may use runtime-loaded MultitouchSupport in the existing Developer ID distribution, but must not link private frameworks at build time or prevent app startup when symbols drift.
- Built-in touch observation, volume adjustment, and supported display-brightness adjustment must not depend on Accessibility authorization.
- APIs unavailable on a particular Mac or macOS release must fail closed, preserve settings, and expose an actionable status rather than crash or repeatedly prompt.
- Trackpad configuration and runtime state remain machine-local and outside iCloud portable fields.

### R2. Required two-finger hold-tap gestures

- Treat the initially left contact as finger A and the initially right contact as finger B.
- When B remains down while A lifts, taps once, and lifts again, execute Volume Up exactly once.
- When A remains down while B lifts, taps once, and lifts again, execute Volume Down exactly once.
- Ordinary two-finger scrolling, simultaneous release, long re-contact, excessive movement, and cancelled frames must not fire either action.
- Timing and movement thresholds must be user-adjustable through the common rule model.

### R3. Required edge gestures

- Recognize a vertical gesture that begins at the extreme left edge and remains inside a configurable edge corridor.
- Upward and downward movement must produce stepped continuous adjustment with rate limiting and no momentum tail.
- The user can bind the edge gesture to volume or brightness, invert direction, and adjust edge width and sensitivity.
- The rule model must also support the other visible edge variants identified during BetterAndBetter inventory when the hardware can distinguish them reliably.

### R4. Custom gesture rules

- Provide ordered, independently enabled gesture rules with stable IDs, human-readable names, trigger configuration, action configuration, and optional per-application inclusion or exclusion.
- Ship the requested hold-tap and left-edge behaviors as editable presets.
- Cover the local BetterAndBetter 2.7.7 touch families with generic configurable recognizers: one- through five-finger tap/double-tap/click/force-click, one-finger regions, two- through five-finger swipes, edge-entry swipes, two- through four-finger pinches, selected-finger tip-taps and swipes, and recorded drawing gestures.
- Match its visible action model with keyboard shortcuts, presets backed by existing Quick Actions/Apple Shortcuts, AppleScript, open app/URL/file/folder, window placement, direct volume/brightness, pointer-window activation, per-app precedence, modifier keys, notes, haptic/HUD feedback, and enabled state.
- Offer BetterAndBetter's visible “suppress left click after a multi-finger tap” behavior as an explicit default-off advanced option; it may consume only the matching click, requires action-specific Accessibility remediation, and must never change passive observation.
- Reuse existing built-in Quick Actions and Apple Shortcuts rather than duplicating their execution logic.
- Support safe local JSON import/export of the complete trackpad rule set and reset to editable presets.

### R5. Settings and diagnostics UX

- Show master enablement, runtime/device status, permission requirements by action, live contact/gesture feedback, the ordered rule list, add/edit/delete/reorder controls, and reset-to-presets.
- Preserve the existing restrained native Settings vocabulary, keyboard navigation, VoiceOver labels, reduced-motion behavior, and English/Simplified Chinese localization coverage.
- Improve Clean Keyboard remediation so denied/suppressed Accessibility authorization offers a direct System Settings route and never asks the user to click a retry path that cannot change state.

### R6. Device lifecycle and safety

- Support built-in and external Apple trackpads when reported by the runtime.
- Reconcile device addition/removal and system wake without duplicating callbacks or actions.
- Process raw frames off the UI path, publish UI diagnostics at a bounded cadence, and execute each recognized discrete gesture at most once.
- Never consume or synthesize ordinary pointer/scroll input merely to observe raw contacts.

## Acceptance Criteria

- [x] Enabling Trackpad on a supported Mac reports at least one active device and disabling it releases every callback.
- [x] The B-held/A-tap sequence raises output volume once; the inverse sequence lowers it once; negative motion/timing cases do not fire.
- [x] A left-edge vertical gesture adjusts the configured volume or brightness target in bounded steps and honors inversion, sensitivity, and edge width.
- [x] Users can create, edit, enable, disable, delete, reorder, scope, reset, import, and export gesture rules, with settings surviving relaunch.
- [x] Every BetterAndBetter trackpad trigger/action category enumerated in R4 is implemented or has a source-backed, user-visible unsupported explanation.
- [x] No Accessibility prompt appears for raw touch observation or built-in volume/brightness actions.
- [x] Optional multi-finger click suppression is off by default, consumes only the matched click when authorized, and otherwise leaves native click/scroll delivery unchanged.
- [x] Clean Keyboard presents accurate current authorization state and an Open System Settings remediation when a fresh prompt is no longer useful.
- [x] Device removal/wake, malformed stored configuration, unsupported private symbols, action failures, and duplicate contact frames fail safely.
- [x] The new pane is reachable from Settings, localized in English and Simplified Chinese, and usable with keyboard and VoiceOver.
- [x] Focused unit/contract tests and an installed-app smoke run cover recognition, persistence, action dispatch, pane wiring, permission UX, and real trackpad input.

## Out of Scope

- Copying BetterAndBetter source code, proprietary assets, product name, or visual trade dress.
- Replicating BetterAndBetter modules unrelated to trackpad gesture recognition and actions selectable from that module.
- Mac App Store compatibility; the existing Developer ID distribution remains the release target.
