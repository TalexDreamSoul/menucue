# Design: metric alert rules and monitor

## Boundaries

Create four layers:

1. `AlertMetricCatalog`: metadata and stable identifiers.
2. `AlertMetricProvider` implementations: typed sampling grouped by cost/source.
3. `AlertRuleEngine`: pure timestamped state transitions.
4. `AlertMonitoringService`: app-lifetime scheduling, rule/provider reconciliation, wake-event intake, persistence, and logical event output.

No provider imports SwiftUI. No rule imports URLSession/channel types. Existing UI services remain visibility-scoped and unchanged.

## Catalog/value model

Use typed values (`number`, `severity`, `event`) and metadata-defined operators. Targeted entries carry a target identity for core, volume, interface, sensor, or fan. Unknown/stale targets remain persisted but unavailable.

Provider groups:

- cheap system counters/capacity/battery;
- GPU/detail probe;
- thermal/fan sensors;
- volume/interface detail;
- dark-wake event bridge.

The monitor computes the union of metric requests from enabled rules, schedules each provider at its catalog minimum cadence, and coalesces all requests for one provider pass.

## State and identity

Rule IDs are UUIDs. Alert event IDs derive from rule ID + transition kind + incident start timestamp/source event ID. Runtime state is versioned and atomically persisted separately from settings.

Numeric state uses alert and recovery boundaries with timestamp durations. Categorical state maps ordered severity. Event state stores source IDs and an enablement baseline. Unavailable samples preserve state but do not accumulate elapsed duration.

On sleep/wake, invalidate counter baselines. On rule edits that change metric/target/operator/boundaries, reset that rule's runtime state without touching other rules.

## Integration

Power diagnostics exposes newly merged normalized wake events or a reconciliation result to the monitor; the monitor never runs another `pmset` query. Logical transitions are handed to the parent notification pipeline through a protocol callback suitable for tests.
