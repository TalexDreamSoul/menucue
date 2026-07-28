# Implementation plan: metric alert rules and monitor

## RED

- Add a catalog completeness table test for every accepted scalar metric/target family.
- Add pure rule-engine tests for numeric/categorical/event paths, boundaries, durations, hysteresis, recovery, cooldown, edits, stale/unavailable values, and relaunch snapshots.
- Add provider tests for normalization, unavailable hardware, target disappearance, counter wrap/priming, and sleep baseline reset.
- Add monitor tests proving provider union/coalescing, cadence bounds, start/stop on enablement, no UI-service retention, dark-wake enablement baseline, and no duplicate backfill.

## GREEN

- Implement catalog IDs/metadata/value formatting and persisted rule models.
- Implement grouped providers by reusing low-level probes, not visibility-owned services.
- Implement pure state engine and versioned atomic runtime store.
- Implement app-lifetime monitor, scheduler, wake bridge, and logical transition callback.
- Wire settings changes and sleep/wake lifecycle without network logic.

## REFACTOR

- Keep catalog metadata as the single source for provider routing, editor fields, units, operators, and variables.
- Measure expensive providers and raise catalog minimum cadences where needed.
- Verify all worker work is off-main and stale generations cannot publish transitions.

## Validation

```sh
swift test --filter AlertMetric
swift test --filter AlertRule
swift test --filter AlertMonitoring
swift test --filter DarkWakeAlert
swift test
./scripts/build-app.sh
```

## Rollback

Stop monitor/timers and remove additive runtime state wiring. Existing SystemMetrics, Dashboard, and Power diagnostics continue unchanged.
