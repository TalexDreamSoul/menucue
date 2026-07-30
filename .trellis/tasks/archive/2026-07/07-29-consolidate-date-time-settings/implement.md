# Implementation Plan

1. Add focused tests for the consolidated pane cases, titles, ordering, and Overview calendar destination.
2. Extract the system time-zone editor from the language view without changing its policy or helper interactions.
3. Replace the three date/calendar/sidebar cases with Date & Time and compose the three visible groups.
4. Rename the language pane/view and retain only language-related controls.
5. Update English and Simplified Chinese localization strings.
6. Run focused tests, localization verification, formatting, and the full Swift test suite.
7. Review the diff for storage, iCloud, and unrelated UI changes.

## Validation Commands

```bash
swift test --filter SettingsInformationArchitectureTests
swift test --filter Localization
swift test
swift-format lint --recursive Sources Tests
```

## Risk and Rollback Points

- `SettingsPane.allCases` controls sidebar order; assert the exact consolidated order.
- Overview links are enum-based and must be updated with the removed calendar case.
- System time-zone behavior must remain service-backed; do not duplicate state in the combined view.
- Localization verification requires exact key parity between English and Simplified Chinese resources.
