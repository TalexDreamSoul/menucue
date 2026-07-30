# Implementation plan: configurable popover tabs and swipe navigation

## 1. RED: ordered-tab model and persistence

- Add tests for default order, arbitrary reorder, duplicate/unknown normalization, missing-tab append, and `SettingsStore` round-trip.
- Add tests that moving by an offset uses a supplied order and wraps at both ends.
- Run focused tests and confirm they fail before production changes.

## 2. GREEN: settings contract

- Make `PopoverTab` a stable codable identity available to `AppSettings` without moving UI-only behavior into the model layer.
- Add normalized `popoverTabOrder` state and reorder helpers to `AppSettings`.
- Add `popoverTabOrder.v1` load/save behavior to `SettingsStore`.
- Add the narrow reorder method to `AppModel`.
- Re-run focused model and persistence tests.

## 3. GREEN: settings UI and shared navigation order

- Add the native reorder list to Overview settings using existing tab titles/icons.
- Pass configured tabs into `PopoverTabBar`.
- Initialize the first popover selection from the configured first tab.
- Route clicks, arrow keys, Status-to-Actions deep-linking, mouse-wheel horizontal input, and swipe relay commands through the same ordered navigation helper.
- Add focused view/model assertions where stable headless checks are possible.

## 4. RED/GREEN: repair gesture delivery from real logs

- Launch the current app with `MENUCUE_SWIPE_LOG=1` and observe one real trackpad gesture.
- When logs show `navigate(...)` without `TAB old -> new`, add a failing identity test for controller/container relay wiring.
- Inject the same `SwipeRelay` into the AppKit container and SwiftUI view, then rerun focused tests and real-trackpad verification.
- Do not change recognizer thresholds without measured evidence.

## 5. Quality and visual verification

- Run localization coverage after adding settings copy.
- Run `swift format lint` on touched Swift files and `git diff --check`.
- Run focused tests, full `swift test`, and `swift build`.
- Render or open Settings to verify the reorder list fits at minimum window size.
- Verify on a real trackpad: one horizontal flick changes one tab; repeated same-direction flicks each work; vertical Calendar/Status scrolling remains smooth.

## Validation commands

```bash
swift test --filter PopoverTabOrderTests
swift test --filter SettingsStoreTimeZoneTests
swift test --filter SwipeRecognizerTests
swift test --filter PopoverSwipeContainerTests
swift test
swift build
swift format lint --recursive <touched Swift files>
git diff --check
```

## Review gates

- Model/persistence tests must be RED before production implementation.
- No implementation approval until `prd.md`, `design.md`, and this plan are reviewed.
- No completion claim without a real trackpad observation.

## Guardrails

- No hidden tabs, new permissions, global event monitors, or iCloud field changes.
- Reuse existing Settings list, motion, SF Symbol, and `AppModel.updateSettings` patterns.
- Keep the persisted payload to stable raw tab IDs; no serialized view metadata.

## Rollback points

- After step 2: model/persistence can be reverted independently of UI.
- After step 3: fall back to default all-cases order without changing the gesture recognizer.
- After step 4: revert only window-level interception if vertical scrolling regresses.
