# Design: NapWatch-inspired Power Diagnostics

## Status

Reviewed and approved for phased implementation.

## Decision summary

Build native Swift functional parity with NapWatch's user-facing power and process capabilities, not a source port or embedded Rust dependency.

Delivery remains phased: read-only power diagnostics, protected power settings, then on-demand process energy diagnostics/actions. This ordering validates expensive/fragile data sources before exposing privileged or destructive operations.

## Boundaries

### Existing modules to extend

- `SystemMetrics.swift` / `SystemMetricsProbe.swift`: battery snapshot and battery-flow primitives that can be sampled with existing Status/Power visibility lifecycle.
- `SystemMetricsService.swift`: only cheap live battery fields; no historical `pmset -g log` parsing.
- `QuickActionService.swift`: surface approved Phase 2 setting intents and feedback.
- `PowerHelperProtocol.swift`, helper `main.swift`, and `PowerHelperManager.swift`: Phase 2 typed privileged setting mutations.

### New modules proposed

- `PowerDiagnostics.swift`: typed settings, wake statistics/events, capability/error states.
- `PowerDiagnosticsProbe.swift`: fixed-path process runner and pure power parsers; native battery methods where available.
- `PowerDiagnosticsService.swift`: refresh coordination, app wake observation, published power snapshot, and 30-day store reconciliation.
- `WakeHistoryStore.swift`: versioned, bounded Application Support persistence and daily projections.
- `ProcessEnergy.swift`: stable process identity, energy-impact sample, detail, and action result contracts.
- `ProcessEnergyProbe.swift`: on-demand energy sampling and process identity/detail lookup.
- `ProcessEnergyService.swift`: scan lifecycle, selection stability, action confirmation state, and stale-result rejection.
- `PowerTabView.swift`: diagnostics UI, process list/detail, and explicit refresh/error states.

Names are provisional and should be checked against the branch state before implementation.

## Architecture

### Live battery path

Use IOPowerSources for level/source/status/estimate where available and IORegistry battery properties for current/voltage/capacity only when no typed public equivalent exists. Keep this probe demand-driven and off the main thread.

Do not shell out to `ioreg` every sample. Do not describe battery-terminal flow as total system power.

### Wake diagnostics path

`PowerDiagnosticsService` owns slow historical data. It registers app-scope sleep/wake notifications, but treats `pmset -g log` as the authoritative recovery source because the process may be suspended during the events being diagnosed.

Refresh triggers:

1. First Power-tab appearance.
2. System wake, after a short coalescing delay.
3. User explicit refresh.
4. App launch only if local history needs reconciliation.

There is no periodic full-log polling.

### Command boundary

A single process runner owns:

- fixed executable paths;
- fixed/typed arguments;
- `LC_ALL=C`;
- exit-status checking;
- bounded execution time;
- stdout size limits where practical;
- cancellation/coalescing;
- conversion from process failure to typed unavailable/error state.

Parsers are pure functions accepting strings, independently tested with fixtures.

### Settings model

Represent each source separately:

```text
PowerProfiles
  battery: PowerProfile?
  ac: PowerProfile?
  ups: PowerProfile?

PowerProfile
  powerMode: supported(PowerMode) | unsupported | unavailable
  powerNap: supported(Bool) | unsupported | unavailable
  wakeOnNetwork: ...
  standby: ...
  tcpKeepalive: ...
```

Never default a missing field to `false`. Never infer all-source intent from the active source.

### Phase 2 mutation path

Add typed XPC methods or one typed enum-backed request with secure coding support. Avoid arbitrary command/key/value strings.

The helper:

1. Validates the requested setting and source.
2. Reads capabilities/current profiles.
3. Executes a fixed `pmset` argument mapping.
4. Re-reads profiles.
5. Returns observed state or an error plus any safely observed state.

The main app publishes only observed state. It may show progress but does not optimistically claim success.

## Process energy and action path

Energy-impact sampling is expensive and must be isolated from `SystemMetricsService`. Start one scan immediately when the process section becomes visible, then no more often than every 15 seconds while it remains visible; pause when hidden/closed and retain explicit manual refresh. Serialize scans and publish the last completed ranking with a timestamp. Evaluate native cumulative process energy counters first; if they cannot provide comparable coverage, use a fixed `/usr/bin/top -l 2 -o power` fallback.

A process action never targets a bare PID. `ProcessIdentity` contains PID, process start time, and observed executable/bundle identity where available. Immediately before SIGTERM or renice, the action boundary re-reads identity and rejects stale selections.

SIGTERM requires explicit confirmation naming the process and PID. For App-mode batch termination, confirmation freezes the current member identities and names the app plus process count; the helper revalidates each frozen identity, never chases newly spawned children, and returns per-process results so partial success is visible. The parity scope does not include SIGKILL. Renice applies only to individual processes, uses a relative delta, clamps to `-20...19`, and returns the observed resulting nice value.

Process actions for root and other users are approved through the existing privileged helper. The XPC surface must remain narrow:

- `terminateProcess(identity:)` means SIGTERM only; no caller-supplied signal.
- `reniceProcess(identity:delta:)` accepts only a bounded relative delta, not an absolute priority or arbitrary arguments.
- The helper re-reads PID, start time, owner UID, and executable identity immediately before acting and rejects any mismatch.
- No application-level protected-target deny list is applied. Root/system targets and batches containing them require stronger typed confirmation that includes the exact process/application identity and member count.
- macOS/kernel enforcement may still reject an operation; helper replies surface that as a typed permission/policy result rather than claiming success.
- Helper replies include observed post-operation state or a typed exited/stale/permission error.

## UI

Add a fourth `Power` tab for the accepted full-parity scope. Keep the existing Status and Actions tabs focused; do not duplicate the full power surface across them.

Recommended layout:

- Top full-width battery band with level/source and charge/discharge flow.
- Compact since-boot counts.
- Full-width sleep/wake timeline, newest first, filterable by event kind only if the initial list proves too noisy.
- Power-profile comparison section showing Battery and AC columns.
- Energy-impact process section with a segmented `App / Process` control over one shared sample, explicit units, last-sampled time, manual refresh, and 15-second visible-only refresh.
- App mode aggregates browser/Electron helpers for diagnosis; Process mode preserves individual stable identities and precise actions.
- Process detail uses a popover/sheet that can receive input; do not reuse the current hover panel's `.allowsHitTesting(false)` behavior for actions.
- SIGTERM uses a destructive confirmation dialog. Renice uses icon controls or a compact stepper with the resulting value visible.
- Phase 2 power actions default to the currently active source and offer explicit Battery/AC/All override; the resolved target is visible before confirmation and sent explicitly to the helper.

Do not add cards inside cards. Reuse `PopoverCard` only for top-level repeated metric groups and preserve the popover's existing density.

## Persistence

Persist normalized wake events and daily counts for 30 days in a versioned, bounded local store under Application Support.

Constraints:

- machine-local only;
- no iCloud sync;
- no process list persistence;
- hard 30-day retention plus a defensive record-count/size ceiling;
- deduplicate with composite event identity while preserving same-second events;
- reconcile after app launch/system wake before pruning;
- migrate or discard unknown future schema safely;
- support a user-visible clear-history command with confirmation.

## Compatibility and failure behavior

- macOS 14 is the deployment floor.
- Portable and desktop Macs must render valid availability states.
- Intel/Apple Silicon and AC/Battery/UPS profiles need fixtures.
- Unsupported settings remain visible only when useful and labelled unavailable; they never appear off.
- Process actions must defend against PID reuse and stale selections.
- A process that exits between scan, detail, confirmation, and action produces a non-destructive stale-process error.
- Cross-user/root visibility and action availability route through approved typed helper capabilities; stale targets remain non-actionable and kernel-denied operations surface their observed failure.
- A parser/command failure preserves the last known snapshot with a staleness marker rather than replacing it with zeroes.
- Refreshes are serialized; newer requests supersede stale results.

## License and attribution

Do not copy Rust source mechanically. If parsing behavior or source structure is substantially adapted, add NapWatch's MIT copyright/license to a repository-level third-party notices artifact before release. MenuCue currently has no root license file, so distribution licensing should be clarified independently.

## Rollout and rollback

- Phase 1 is additive and read-only; rollback removes the Power tab/service without changing system state.
- Phase 2 helper changes are capability/version gated. Older helpers enter the existing refresh-required path.
- User-authored power settings are persistent system policy, not app-owned transient state; helper removal must not silently restore them. This differs from MenuCue's managed `disablesleep` behavior.
- Each phase should be independently releasable and revertible.

## Open product decisions

None. The design was reviewed and approved for implementation.
