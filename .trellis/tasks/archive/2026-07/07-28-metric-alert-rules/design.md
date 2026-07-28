# Design: metric alert rules and monitor

## Boundaries

Create six layers:

1. `AlertMetricCatalog`: metadata and stable identifiers.
2. `AlertMetricProvider` implementations: typed sampling grouped by cost/source.
3. `NotificationTemplateRenderer`: fixed allowlist parsing and deterministic message rendering.
4. `AlertRuleEngine`: pure timestamped state transitions.
5. `NotificationRuntimeStore`: atomic rule/cursor/rendered-message outbox durability and claim/ack state.
6. `AlertMonitoringService`: app-lifetime scheduling, rule/provider reconciliation, wake-event intake, persistence transactions, and delivery-work signalling.

No provider imports SwiftUI. No rule imports URLSession/channel types. Existing UI services remain visibility-scoped and unchanged.

## Catalog/value model

Use typed values (`number`, `severity`, `boolean`, `event`) and metadata-defined operators. The exact set is the parent `research/metric-inventory.md`; a literal expected-ID test prevents the catalog from defining an incomplete version of “all”. Targeted entries carry a target identity for core, volume, interface, sensor, or fan. Unknown/stale targets remain persisted but unavailable.

Before thermal rules, replace `ThermalReading.id == label` with a separate nonlocalized `sensorID`: `hid:<cluster-kind>` for known HID aggregates and `smc:<key>` for Intel sensors. Any additional raw sensor identity must remain distinct even when `kind == .other`. Labels remain localized display text; legacy label targets are never guessed across locale changes and become explicitly unavailable.

Provider groups:

- cheap system counters/capacity/battery;
- GPU/detail probe;
- thermal/fan sensors;
- volume/interface detail;
- dark-wake event bridge.

The monitor computes the union of metric requests from enabled rules, schedules each provider at its catalog minimum cadence, and coalesces all requests for one provider pass.

## State and identity

Rule IDs are UUIDs. Alert event IDs derive from rule ID + transition kind + incident start timestamp/source event ID. One versioned `NotificationRuntimeStore` atomically commits next rule state, source cursor, rendered message snapshot, target channel set, and outbox record. It also owns claim leases, attempts, retry times, and per-channel acknowledgements.

Numeric state uses alert and recovery boundaries with timestamp durations. Categorical state maps ordered severity. Event state stores source IDs and an enablement baseline. Unavailable samples preserve state but do not accumulate elapsed duration.

On sleep/wake, invalidate counter baselines. On rule edits that change metric/target/operator/boundaries, reset that rule's runtime state without touching other rules.

## Integration

Power diagnostics exposes newly merged normalized wake events or a reconciliation result to the monitor; the monitor never runs another `pmset` query. Move the current unconditional workspace wake observer behind a reference-counted history-monitor lifecycle shared by existing Power history and enabled dark-wake rules. Dark-wake-only mode calls history reconciliation only.

When rule evaluation transitions, render the configured message and atomically commit state, source cursor, rendered message, and the snapshot of currently enabled channel kinds before signalling that delivery work is available. The coordinator claims by stable event ID; there is no callback-only durability gap. Discovered dark wakes attempt delivery immediately, and pending leases/retries resume on full wake.
