# BetterAndBetter 2.7.7 touchpad inventory

Observed locally from `/Applications/BetterAndBetter.app` on 2026-08-23. The app is `LSUIElement=true`; its Preferences window was opened with Command–Comma and traversed through computer-use. Existing rules were not edited, saved, imported, exported, reset, or updated.

## Information architecture

Touchpad has three tabs:

1. Gesture recognition — a live trackpad visualization.
2. Gesture settings — application scope plus ordered rules.
3. Function settings — drawing activation and global gesture behavior.

Application scopes include All Applications and individual apps. The UI explicitly states that app-specific rules take precedence over All Applications.

Each rule exposes stable fields:

- enabled
- modifier key
- gesture
- action
- activate window below cursor
- note

The page provides scope add/remove, rule add/remove, reset, and instructions.

## Trigger catalog

The installed `Preferences.strings` contains 89 touch menu entries. They reduce to these configurable families:

- One through five fingers: tap, double tap, click, force click.
- One finger: center, left/right side, four corners, and four edge-middle regions for tap/click.
- Two through five fingers: swipe up/down/left/right.
- Two fingers: enter from top/bottom/left/right edge.
- Two through four fingers: pinch in/out.
- Two fingers: selected left/right finger tip-tap with near/normal/far spacing.
- Three/four fingers: selected left/middle/right finger tip-tap.
- Two through four fingers: selected left/right finger directional swipe while other contacts remain.
- Drawing path: modifier plus one finger, or bottom thumb plus another finger.

Directly visible installed rules confirmed four corner taps, three-finger selected-finger horizontal swipes, three-finger selected-finger taps, and recorded drawing paths.

## Actions and conditions

The local action picker exposes four top-level categories: Shortcut Keys, Preset, AppleScript, and Simulate Trackpad Gesture. Its warning says simulated trackpad gestures apply to the normal-mouse module, so that cross-module bridge is not a touchpad requirement.

Directly visible touch rules confirmed:

- 1/4 window placement in all four corners.
- 1/2 window placement on all four sides.
- Center window.
- Open a specified link.
- Open an app, URL, file, or folder.
- Execute keyboard shortcuts.
- Increase/decrease Mac display brightness.

Shared BetterAndBetter action surfaces additionally show moving a window to another desktop/display, maximizing, opening Preferences, exit/restart, screen saver, lock screen, minimize/restore all windows, and internal/external display brightness. These are shared-action evidence, not proof that every item was selectable from the touch rule editor.

Conditions and feedback:

- none/Fn/Shift/Control/Option/Command modifiers
- app-specific precedence and global blacklist behavior
- optional activate-window-under-cursor flag
- rule notes used for action feedback
- optional haptic feedback

## Function settings

Confirmed switches:

- Modifier + one-finger drawing, with modifier picker.
- Bottom-thumb + another-finger drawing.
- Bridge to normal-mouse right-button drawing.
- Suppress native left click during multi-finger tap.
- Haptic feedback when an action triggers.

MenuCue will implement drawing rules directly against any action rather than fabricate BetterAndBetter's mouse-module bridge. Multi-finger click suppression remains explicit, default-off, and action-permission gated; passive raw observation remains pass-through.

## Transfer and management

The separate Rule Management page shows import rules, export highlighted rules, iCloud upload/download, backup state, delete, and reset all settings/rules. MenuCue will provide local JSON import/export and reset-to-presets. Trackpad rules remain machine-local because they contain device and local-app identities.

## Permission observations

No permission explanation, authorization button, or retry state was visible in the three touchpad tabs. This does not establish that BetterAndBetter requires no macOS permissions. MenuCue must query and explain each capability itself.

## Safe screenshots

- [Gesture recognition](gesture-recognition.png)
- [Function settings](function-settings.png)
- [Modifier menu](modifier-menu.png)
- [Edge actions](edge-actions.png)

A Gesture Settings table screenshot was inspected to build the inventory but was not persisted because it contained existing user-authored rule notes and app labels.
