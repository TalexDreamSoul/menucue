# Implementation plan: signed statutory holiday data and overrides

## Delivery order

1. `07-30-holiday-publishing-pipeline` freezes canonical manifest/signature fixtures and produces the bundled revision.
2. `07-30-holiday-client-feed` consumes only those fixtures and owns transport, validation, freshness, and fallback.
3. `07-30-holiday-overrides-sync` consumes the typed schedule store and owns UI plus iCloud convergence.
4. This parent runs contract and cross-child integration verification; it does not duplicate child implementation.

## RED: publishing pipeline

- [ ] Add adapter fixtures for official normalized input, LunarBar-compatible JSON, malformed keys/statuses, and source conflicts.
- [ ] Add deterministic manifest and detached-signature golden tests locking sorted-key JSON, timestamp/escaping/newline rules, signature-envelope fields, and digest encoding.
- [ ] Add publication-blocking tests for missing official provenance and unresolved conflict.

## GREEN: publishing pipeline

- [ ] Implement typed source adapters, normalizer, comparator, review input, deterministic manifest builder, and signer.
- [ ] Add a bundled current snapshot with documented official references and license/provenance record.
- [ ] Add CI/manual commands that never print or persist the production private key.

## RED: client and settings

- [ ] Add transport/validator tests for every malformed, oversized, bad-signature, regressive, and out-of-coverage case.
- [ ] Add fallback/conditional-request/jitter tests plus executable `completeYears`/`validThrough` fresh/stale/unavailable/update-failure states with an injected transport and clock.
- [ ] Add resolution-precedence and visual-override tests.
- [ ] Add normal per-date merge, `(modifiedAt, origin)` tie, union writeback, permanent tombstone, specialized pre-LWW import, first/account merge, `Use iCloud`, `Use This Mac`, higher-generation reset/source choice, long-offline resurrection, payload-budget, migration, and offline tests.

## GREEN: client and UI

- [ ] Implement typed manifest decoder, signature validator, store, update service, atomic cache, and status model.
- [ ] Integrate resolved markers/provenance with shared month/day projections.
- [ ] Add selected-date override controls and Calendar and Events update status/manual refresh.
- [ ] Extend `SettingsStore` and `PreferenceSyncService` with the per-entry merge map and `CN` first default.

## REFACTOR

- [ ] Ensure upstream payload parsing exists only in publishing adapters and canonical payload parsing exists only at the client boundary.
- [ ] Ensure views never inspect raw JSON, signatures, source ids, or UserDefaults.
- [ ] Verify cache/feed data never enters iCloud and user overrides never enter downloaded files.

## Validation

```bash
swift test --filter Holiday
swift test --filter PreferenceSync
swift test --filter Localization
./scripts/verify-localizations.swift \
  Sources/MenuCue/Resources/en.lproj/Localizable.strings \
  Sources/MenuCue/Resources/zh-Hans.lproj/Localizable.strings
swift test
swift build
```

Run the pipeline twice against frozen fixtures and compare manifest SHA-256. Manually test valid update, offline launch, stale coverage, bad signature, cached rollback, override/reset, and update diagnostics in the packaged app.
