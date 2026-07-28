# Metric alert rules and background monitor

## Goal

Turn all current stable scalar metrics plus dark-wake events into configurable, low-overhead alert observations and exactly one logical alert/recovery transition per incident.

## Requirements

- Define catalog-driven metric IDs, metadata, targets, values, units, operators, availability, formatting, and provider ownership.
- Catalog aggregate/per-core CPU, load averages, GPU utilization/memory, memory usage/pressure, swap, storage capacity/I/O, network rates, temperatures, fan RPM/load, battery level/flow, and applicable power readings.
- Exclude ranked/list/configuration domains from generic scalar rules and keep dark wake as a typed event rule.
- Support numeric above/below, categorical severity, event occurrence, sustained duration, recovery threshold/duration, hysteresis, and cooldown.
- Use timestamp-based evaluation with a fake clock; missing/stale/unavailable samples do not advance durations.
- Persist incident state, dark-wake cursor, logical event IDs, and per-channel delivery handoff state locally.
- Create an app-lifetime monitor that groups enabled rules by provider and samples only needed metrics while the UI is closed.
- Keep provider baselines independent from UI services and reset rate baselines across sleep/wake or reconfiguration.
- Bridge normalized dark-wake events without reparsing `pmset`; enabling a rule establishes a baseline instead of replaying retained history.
- Emit typed variable contexts for alert and recovery templates without performing rendering or network delivery.

## Acceptance Criteria

- [ ] Every included scalar metric has a stable catalog entry and focused available/unavailable/unit/operator test.
- [ ] Dynamic lists/configuration are absent from the scalar catalog and documented as future typed rule kinds.
- [ ] State-machine tests cover pending alert, active, interrupted recovery, stable recovery, cooldown, threshold equality, timestamp gaps, stale data, and relaunch.
- [ ] Dark-wake reconciliation/backfill emits each post-enable source event once and never mutates wake history.
- [ ] No enabled metric rules means no timer/probe work; adding/removing rules starts/stops only required providers.
- [ ] Expensive probes are cadence-bounded and shared across rules that request the same observation.
- [ ] Counter-derived rates cannot alert on the first unprimed sample or across sleep.
- [ ] Focused rule/monitor tests, full `swift test`, and app build pass.

## Dependencies

Consumes the shared logical event/message handoff contract from `07-28-notification-transport`; tests must remain runnable with fakes.
