# Implementation plan: metric alert rules and monitor

## RED

- Add a literal catalog completeness test matching every Included row in the parent inventory and asserting every Excluded row remains intentionally absent.
- Add stable thermal-ID tests across locale changes, explicit HID/SMC namespaces, duplicate `.other` sensors, and legacy label-target migration to unavailable.
- Add pure template parser/renderer tests for allowlists, unknown/repeated variables, Unicode, missing optional context, output limits, and defaults.
- Add pure rule-engine tests for numeric/categorical/boolean/event paths, boundaries, durations, hysteresis, recovery, cooldown, edits, stale/unavailable values, and relaunch snapshots.
- Add provider tests for normalization, unavailable hardware, target disappearance, primary-network interface changes, independent cross-accelerator GPU maxima, counter wrap/priming, and sleep baseline reset.
- Add monitor tests proving provider union/coalescing, cadence bounds, start/stop on enablement, no UI-service retention, reference-counted wake observer/history timer, dark-wake-only history reconciliation, enablement baseline, atomic enqueue plus coordinator kick, full-wake pending-outbox resume, and no duplicate backfill.
- Add crash-injection tests before/after atomic transition+outbox commit, claim lease, retry schedule, remote result, and acknowledgement.

## GREEN

- Implement catalog IDs/metadata/value formatting and persisted rule models, including stable nonlocalized thermal sensor identity.
- Implement deterministic template parsing/rendering and typed variable contexts.
- Implement grouped providers by reusing low-level probes, not visibility-owned services.
- Implement pure state engine and one versioned atomic runtime/outbox store with claim leases and per-channel acknowledgements.
- Implement app-lifetime monitor, scheduler, reference-counted wake-history bridge, and delivery-work notification.
- Move the existing unconditional wake observer into that lifecycle and ensure dark-wake-only monitoring never executes full diagnostics.

## REFACTOR

- Keep catalog metadata as the single source for provider routing, editor fields, units, operators, and variables.
- Measure expensive providers and raise catalog minimum cadences where needed.
- Verify all worker work is off-main and stale generations cannot publish transitions.

## Validation

```sh
swift test --filter NotificationTemplate
swift test --filter AlertMetric
swift test --filter AlertRule
swift test --filter AlertMonitoring
swift test --filter DarkWakeAlert
swift test
./scripts/build-app.sh
```

## Rollback

Stop monitor/timers and remove additive runtime state wiring. Existing SystemMetrics, Dashboard, and Power diagnostics continue unchanged.

## Completion

Completed in `bc31c95`: the 41-metric catalog, persisted rule engine, dark-wake cursor,
atomic runtime/outbox store, and app-lifetime monitor pass focused and full test suites and shipped
in MenuCue v0.6.0 (build 16).
