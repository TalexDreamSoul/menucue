# Implementation plan: holiday visual overrides and iCloud merge

## RED

- [ ] Add resolution-precedence and feed-refresh override-retention tests.
- [ ] Add marker/accessibility and selected-detail state projection tests.
- [ ] Add ordinary higher-remote replacement, higher-local rejection/repair, equal-generation out-of-order merge/tie, specialized pre-LWW import, union-writeback, echo suppression, permanent tombstone, first/account merge, `Use iCloud`, `Use This Mac`, reset generation, long-offline resurrection, and payload-limit tests.
- [ ] Add CN default, migration, local-only failure, and iCloud exclusion tests.

## GREEN

- [ ] Add typed override models, local persistence, resolver, and AppModel mutations.
- [ ] Extend portable settings with generation/per-date merge and anti-entropy writeback.
- [ ] Add month markers, selected-date controls/provenance, sync-overflow status, and localization.

## REFACTOR AND VALIDATE

```bash
swift test --filter HolidayOverride
swift test --filter PreferenceSync
swift test --filter Localization
./scripts/verify-localizations.swift \
  Sources/MenuCue/Resources/en.lproj/Localizable.strings \
  Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings
swift test
swift build
```

Manual checks cover override/reset after feed revision, offline/local use, two-device convergence, and maximum accessibility text.
