# MenuCue integration analysis

## Existing architecture

MenuCue already has most of the infrastructure NapWatch lacks:

- A native SwiftUI menu bar app targeting macOS 14+: `Package.swift:4-48`.
- A demand-driven metrics service that only samples while the Status tab is visible: `Sources/MenuCue/SystemMetricsService.swift:4-8`, `150-175`.
- Public Darwin/sysctl/IOKit probes for CPU, memory, disk, network, and power-source state: `Sources/MenuCue/SystemMetricsProbe.swift:26-30`; `Sources/MenuCue/MetricsSampling.swift:109-140`.
- Expensive detail probes isolated from the regular sample loop and activated only on hover: `Sources/MenuCue/SystemDetailService.swift:25-28`, `47-105`.
- An existing signed privileged helper installed through `SMAppService`, reached over XPC, with client code-signature validation: `Sources/MenuCue/PowerHelperManager.swift:58-138`, `Sources/MenuCueHelper/main.swift:287-365`.
- Helper protocol versioning/capabilities and observed read-back after protected mutations: `Sources/MenuCueHelperProtocol/PowerHelperProtocol.swift:3-16`, `Sources/MenuCueHelper/main.swift:64-73`, `177-205`.
- Existing Low Power Mode and sleep-disable quick actions: `Sources/MenuCue/QuickActionService.swift:174-186`, `370-410`.

The in-flight metrics work is uncommitted user work. Integration planning must build around it without editing or restructuring it prematurely.

## Capability matrix

| NapWatch capability | Decision | MenuCue shape | Rationale |
|---|---|---|---|
| Battery percentage/source/charging/estimate | Adapt | Extend the native metrics model/probe | Strong fit; avoid `pmset` when IOPowerSources provides typed data |
| Instant battery Watts and %/hour | Adapt with corrected naming | “Battery flow” on portable Macs only | Useful, but not total system power draw |
| Sleep/dark-wake/user-wake counts | Adapt | Read-only Power Diagnostics service | Valuable and cheap when queried on demand |
| Sleep/wake event feed | Adapt, redesign lifecycle | Power tab timeline refreshed on open/app wake | Full-log polling every 16 seconds is unacceptable |
| Power-setting overview | Adapt | Per-power-source typed profile model | Must preserve AC/battery differences and unknown/unsupported states |
| Power Nap/Wake-on-LAN/standby/TCP keepalive toggles | Phase 2 | Typed helper capabilities + quick actions | Existing XPC helper is safer than cached sudo |
| Low Power Mode toggle | Reuse existing | Existing quick action/helper | Already implemented more correctly than upstream |
| Settings explanations | Adapt | Power tab/settings help text | Useful product content, verify wording against `pmset(1)` |
| Top energy-impact processes | Phase 3, redesign | On-demand scan with measured cadence | Functional parity accepted; `top -l 2` costs ~4 s and cannot join the normal metrics timer |
| Process detail | Phase 3, reuse native patterns | Extend on-demand detail architecture | Existing service already isolates expensive per-process inspection |
| Kill process | Phase 3, safety-gated | Confirmed SIGTERM with stable process identity | Functional parity accepted; must mitigate PID reuse and ownership risk |
| Renice process | Phase 3, safety-gated | Bounded relative priority change with observed result | Functional parity accepted; raising priority may require privilege |
| Cached sudo ticket | Reject | Existing SMAppService/XPC helper | Inferior security and UX |
| Rust/ratatui/crossterm | Reject | Native Swift only | No architectural or UX fit |
| In-memory-only wake history | Replace in Phase 1 | Versioned 30-day machine-local event store + daily counts | Cross-reboot diagnosis is approved; never iCloud-sync machine telemetry |

## Recommended product scope

### Phase 1: read-only Power Diagnostics

Add a dedicated `Power` popover tab rather than crowding the existing Status card grid.

Show:

- Battery source, level, charging state, estimate, and truthful charge/discharge flow.
- Since-boot Sleep, Dark Wake, and User Wake counts.
- Recent normalized Sleep/DarkWake/Wake timeline with reason.
- Bounded 30-day cross-reboot local history and daily dark-wake summaries.
- Current AC and Battery power profiles for supported settings.
- Explicit unavailable/unsupported/error states instead of false/zero fallbacks.

Do not add mutations in this phase. The parser and UI can be validated on varied macOS fixtures before touching protected settings.

### Phase 2: controlled settings

Extend the existing helper with typed operations for Power Nap, Wake for network access, Standby, and TCP Keepalive.

Requirements:

- No generic `setPMSet(key:value:)` XPC API.
- Callers choose a typed setting, target power source (`battery`, `ac`, or explicit `all`), and value.
- Helper validates capability using `pmset -g cap` or parsed profile presence.
- Every mutation re-reads state and returns the observed profile.
- UI warns when “all power sources” would erase a deliberate AC/battery difference.
- Helper protocol/capability version increments; stale helpers remain blocked by existing refresh logic.

### Phase 3: process energy diagnostics and actions

Deliver the accepted full-parity process surface without adding it to the normal metrics loop:

- On-demand energy-impact ranking with explicit “Energy impact, not Watts” labelling.
- Stable process identity containing PID plus process start time (and observed executable identity where available) so a reused PID cannot receive an action intended for an exited process.
- Process detail using native `proc_*`/bundle inspection where possible and fixed-path command fallbacks only when necessary.
- SIGTERM only after explicit confirmation; no force-kill in the parity scope.
- Relative renice with valid-range clamping and an observed resulting nice value.
- Current-user, root, and other-user actions route through narrowly typed privileged-helper operations with process identity revalidation immediately before the action.
- Explicit helper policy rejection for stale identities and protected critical targets; no process-name-only allow/deny decisions.
- No process list/path history in local persistence or iCloud.

## Proposed data flow

```text
IOPowerSources / IORegistry
          -> BatteryProbe
          -> live PowerSnapshot while Power/Status UI is visible

pmset -g stats / -g log / -g custom / -g cap
          -> ProcessRunner (fixed executable, LC_ALL=C, status checked, timeout)
          -> fixture-tested typed parsers
          -> PowerDiagnosticsService
          -> versioned 30-day local event store
          -> Power tab

Power setting intent
          -> QuickActionService or Power tab command
          -> PowerHelperManager
          -> versioned typed XPC protocol
          -> root helper allowlist
          -> pmset mutation
          -> pmset observed read-back
          -> published authoritative state

Energy scan request while Power tab is visible
          -> ProcessEnergyService (coalesced, measured cadence)
          -> native process counters when sufficient, otherwise fixed `/usr/bin/top` sample
          -> stable ProcessIdentity (PID + start time + observed executable)
          -> process detail / confirmed action
          -> direct user-owned operation or typed helper operation (pending policy)
          -> identity revalidation immediately before SIGTERM/renice
          -> observed completion/state
```

## Lifecycle

The sleep timeline cannot simply be added to `SystemMetricsService`'s visible-only timer:

- Live battery flow belongs in the existing demand-driven sampling loop.
- Historical sleep/dark-wake refresh belongs in a separate service because the relevant events occur while the app/UI is not sampling.
- Register lightweight `NSWorkspace` sleep/wake notifications at app scope.
- Query historical `pmset` data on first Power-tab open, after system wake, and on explicit refresh. Do not poll the full log continuously.
- Serialize refresh work and cancel/coalesce duplicate requests; `pmset -g log` took 4.48 s on the audit machine.

## Data contracts

Use explicit unknown/error states:

- `BatteryFlowState`: unavailable, charging, discharging, idle.
- `PowerSettingValue<T>`: supported(value), unsupported, unavailable(error).
- `PowerProfile`: battery, AC, UPS if present; never flatten profiles implicitly.
- `WakeEvent`: stable identity from timestamp + kind + full normalized reason + occurrence index/UUID when available. Same-second events must survive.
- `WakeStatistics`: counts plus boot date, since counts reset at reboot.

All telemetry and policy settings are machine-local. Do not add them to `PortableSettingField` or iCloud envelopes.

## Security, privacy, and distribution

- Read-only `pmset`, `ioreg`, and IOPowerSources access requires no new entitlement on the current non-sandboxed distribution.
- Mutations must stay inside the signed helper. Existing XPC code-signature validation is the correct trust boundary.
- The helper plist, protocol version, capability bitset, and package/build scripts will need synchronized changes in Phase 2.
- Process lists can expose usernames, executable paths, and running applications. Do not persist them or include them in diagnostics exports by default.
- Wake reasons may reveal attached hardware or network activity. Keep history local and provide clear retention controls if persistence ships.
- No Rust binary or third-party package should be bundled.

## Key risks

| Risk | Severity | Mitigation |
|---|---|---|
| Privileged process control targets the wrong/reused PID | Critical | Stable identity in request; helper revalidates PID/start time/UID/executable immediately before action |
| Root helper terminates a critical system process | Critical (accepted product risk) | SIGTERM-only typed API, exact typed confirmation for root/system targets, identity revalidation, observed failures, disposable-process tests only; no app deny list by decision |
| Full-log polling drains power | High | Event-driven/on-demand refresh; coalescing; measured timeouts |
| AC/battery profiles overwritten | High | Per-source model and explicit mutation target |
| Unsupported/missing parsed as off | High | Tri-state typed values and subprocess status validation |
| `powermode`/`lowpowermode` drift | High | Capability/profile fixtures across OS/hardware; existing dual-key handling |
| UI claims battery flow is system Watts | Medium | Truthful labels and availability semantics |
| Same-second wake events dropped | Medium | Composite identity and fixture regression |
| Helper/API version mismatch | Medium | Increment protocol/capabilities; existing refresh-required state |
| Telemetry leaks through iCloud/export | Medium | Machine-local storage only; no process persistence |
| Upstream parser drift | Medium | Own Swift fixtures; upstream is reference, not runtime dependency |

## Evidence gaps requiring implementation-time fixtures

- Intel Mac and desktop Mac output shapes.
- macOS 14/15/26 `pmset` format differences.
- UPS profile output.
- Locale behavior of command output.
- Behavior when FileVault, standby, or Power Nap is unsupported.
- App wake-notification ordering relative to `pmset` log finalization.
