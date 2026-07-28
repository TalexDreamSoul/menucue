# Metric alert rules and background monitor

## Goal

Turn the complete reviewed alert-metric catalog plus dark-wake events into configurable, low-overhead observations and exactly one logical alert/recovery transition per incident.

## Requirements

- Define catalog-driven metric IDs, metadata, targets, values, units, operators, availability, formatting, and provider ownership matching every Included row in the parent `research/metric-inventory.md`.
- Add a stable nonlocalized thermal sensor ID before selected-sensor rules. HID cluster IDs and Intel SMC-key IDs use explicit namespaces, duplicate `.other` sensors remain distinct, labels remain display-only, and legacy label targets become unavailable without guessed migration.
- Exclude ranked/list/configuration domains from generic scalar rules and keep dark wake as a typed event rule.
- Support numeric above/below, categorical severity, event occurrence, sustained duration, recovery threshold/duration, hysteresis, and cooldown.
- Use timestamp-based evaluation with a fake clock; missing/stale/unavailable samples do not advance durations.
- Define the fixed `{{variable}}` template parser/renderer and typed variable context used to snapshot `NotificationMessage` values at transition time.
- Persist each rule transition, source cursor, rendered message snapshot, target enabled-channel set, and new outbox record in one atomic versioned transaction; expose idempotent claim/ack operations to the delivery coordinator.
- Add crash-injection coverage around commit, claim lease, retry scheduling, and acknowledgement.
- Create an app-lifetime monitor that groups enabled rules by provider and samples only needed metrics while the UI is closed.
- Keep provider baselines independent from UI services and reset rate baselines across sleep/wake or reconfiguration.
- Bridge normalized dark-wake events without reparsing `pmset`; enabling a rule establishes a baseline instead of replaying retained history.
- Reference-count wake history observation between the Power-history feature and dark-wake rules. Zero references means no observer/timer; dark-wake-only mode performs history reconciliation, not full diagnostics.
- Atomically queue discovered dark wakes, attempt immediate delivery, and resume pending outbox work on full wake.
- Use the configured template renderer to produce alert/recovery messages before the atomic transition/outbox commit; no network delivery occurs in rule evaluation.

## Acceptance Criteria

- [ ] A literal expected-ID test matches every Included row in the parent metric inventory, and all Excluded rows remain documented with rationale.
- [ ] Thermal targets remain stable across language changes; HID/SMC namespaces cannot collide; duplicate `.other` sensors remain distinct; unresolved legacy label targets become unavailable without retargeting.
- [ ] Template tests cover allowed/unknown/repeated variables, Unicode, missing optional context, output limits, alert/recovery defaults, and deterministic rendering.
- [ ] Dark-wake reconciliation/backfill atomically queues each post-enable source event once, attempts delivery when discovered, resumes on full wake, and never mutates wake history.
- [ ] With no Power-history feature and no dark-wake rule, no wake observer/history timer runs; dark-wake-only mode never runs profiles/assertions diagnostics.
- [ ] No enabled metric rules means no notification-owned timer/probe work; adding/removing rules starts/stops only required providers.
- [ ] Expensive probes are cadence-bounded and shared across rules that request the same observation.
- [ ] Counter-derived rates cannot alert on the first unprimed sample or across sleep.
- [ ] State-machine tests cover pending alert, active, interrupted recovery, stable recovery, cooldown, threshold equality, timestamp gaps, stale data, and relaunch.
- [ ] Crash-injection tests prove atomic transition/outbox handoff cannot lose or logically duplicate an alert.
- [ ] Focused rule/monitor tests, full `swift test`, and app build pass.

## Dependencies

Consumes the shared logical event/message handoff contract from `07-28-notification-transport`; tests must remain runnable with fakes.
