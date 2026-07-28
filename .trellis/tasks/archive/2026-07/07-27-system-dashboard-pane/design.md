# Design — System Dashboard pane

## 1. Boundaries

Three layers, matching the existing split in `Sources/MenuCue/`:

| Layer | Files | Rule |
|---|---|---|
| Probe (Foundation/Darwin/IOKit only) | `SystemMetricsProbe`, `SystemDetailProbe`, `SystemSensorReader`, **new** `DashboardProbe` | Pure reads. Never traps, never blocks the main thread, degrades an unavailable counter to `nil`/empty — never to a zero that reads as a measurement. |
| Model (Foundation only) | `SystemMetrics.swift`, **new** `DashboardModels.swift` | Value types + derived properties + formatting. No `Color`, no SwiftUI. |
| Service (`ObservableObject`) | `SystemMetricsService`, `SystemDetailService`, **new** `DashboardMetricsService` | Owns timers and refcounted lifetime. Publishes snapshots. |
| View (SwiftUI) | `StatusTabView`, **new** `DashboardView` + section views + `DashboardComponents` | Maps model → tint/label. No `UserDefaults`, no probes. |

Non-negotiable from `.trellis/spec/frontend/state-management.md`: views send intent through
`AppModel`; services own runtime state. The Dashboard reads settings and never writes them.

## 2. Probe additions — all verified on this Mac before design

Each was compiled and run against the live system (`/tmp/probecheck`) rather than assumed:

| Reading | Interface | Verified result on M4 Pro |
|---|---|---|
| Per-core ticks | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 14 cores, user/system/idle/nice per core |
| Core cluster | `IOPlatformDevice` → `cluster-type` (CFData "E"/"P") + `logical-cpu-id` | E = cpu 0–3, P = cpu 4–13 |
| Load average | `getloadavg(_:3)` | 3 values returned |
| Swap | `sysctlbyname("vm.swapusage")` → `xsw_usage` | total 18.25 GB, used 16.63 GB, encrypted |
| Memory pressure | `sysctlbyname("kern.memorystatus_vm_pressure_level")` → `Int32` | level 2 (warning) |
| Volumes | `FileManager.mountedVolumeURLs` + `.volumeLocalizedFormatDescriptionKey`, `.volumeIsInternalKey`, `.volumeIsBrowsableKey` | APFS / Mac OS Extended / NFS, internal flag correct |
| Per-interface | `getifaddrs` `AF_LINK` → `sockaddr_dl` MAC + `if_data` byte counters | en0 MAC + 2.16 GB in / 3.93 GB out |
| Disk IOPS | `IOBlockStorageDriver` → `Statistics["Operations (Read)"/"Operations (Write)"]` | present on every block device |

`cluster-type` is the authoritative core-topology source. It is read **once** (topology is
static) and cached. Fallback chain if the property is missing (Intel, future hardware):
`hw.nperflevels` + `hw.perflevelN.logicalcpu` + `hw.perflevelN.name`, walking perflevels in
reverse index order because XNU numbers CPUs slowest-cluster-first. If neither source yields
a partition covering exactly the reported core count, cores render **unlabelled** rather than
mislabelled.

Deliberately excluded: CPU frequency (no public API on Apple silicon) and GPU core count
(no public sysctl). The GPU tab identifies the GPU by `hardware.chipName` — accurate on
Apple silicon where the GPU is on the SoC.

## 3. New model types (`DashboardModels.swift`)

```swift
enum DashboardSection: String, CaseIterable, Identifiable { case cpu, gpu, memory, storage, network, sensors }
enum CoreCluster { case performance, efficiency, unspecified }
struct CoreLoad: Identifiable { let index: Int; let busy: Double; let cluster: CoreCluster }
struct LoadAverage: Equatable { var one, five, fifteen: Double }
struct SwapUsage: Equatable { var used, total: UInt64; var isEncrypted: Bool; var fraction: Double }
enum MemoryPressureLevel: Int { case normal = 1, warning = 2, critical = 4 }
struct VolumeUsage: Identifiable { let path, name, format: String; let used, total: UInt64; let isInternal: Bool }
struct NetworkInterfaceInfo: Identifiable { let name: String; let ipv4, macAddress: String?; let bytesIn, bytesOut: UInt64 }
struct DiskOperationRates: Equatable { var readsPerSecond, writesPerSecond: Double; var totalBytesRead, totalBytesWritten: UInt64 }
struct MetricHistory: Equatable { private(set) var values: [Double]; let capacity: Int; mutating func append(_:) }
```

`DashboardSnapshot` aggregates the section-gated readings. It is **not** `Codable` and
**not** persisted — this sidesteps a `SystemMetricsSnapshot` cache-schema migration entirely
(a synthesized `Codable` decoder requires every non-optional key, so widening the cached
struct would silently invalidate existing caches).

`MemoryPressureLevel.decode(_ raw: Int32) -> MemoryPressureLevel?` returns `nil` for values
outside {1,2,4} so an unrecognised kernel value shows "Unknown", not a wrong severity.

## 4. Sampling architecture

```
DashboardView
├── @StateObject metrics   = SystemMetricsService(historyCapacity: 120)   // base snapshot, CPU history
└── @StateObject dashboard = DashboardMetricsService()                    // section-gated extras + rate histories
```

Two services rather than one because their cadences and costs differ by an order of
magnitude — exactly the reason `SystemDetailService` already exists separately from
`SystemMetricsService`.

**Rate histories are derived, not re-measured.** `DashboardMetricsService.attach(to:)`
subscribes to `metrics.$snapshot` via Combine and appends disk read/write, network down/up,
and fan RPM into `MetricHistory` ring buffers. Sampling those counters a second time would
create an independent baseline and print numbers that disagree with the popover's.

Histories are appended for **every** section, not just the visible one, so switching to
Network shows an already-populated chart instead of an empty box. Appending to a ring buffer
is free; the gating exists for probes, not for arithmetic.

**Section gating.** A 2 s timer dispatches only the active section's probes onto a utility
queue, guarded by a `generation` counter (same late-result guard `SystemDetailService` uses):

| Section | Probes run |
|---|---|
| cpu | per-core ticks, load average, thermal breakdown |
| gpu | GPU stats, thermal breakdown |
| memory | top processes (limit 10), swap, memory pressure |
| storage | mounted volumes, disk operation counters |
| network | interface enumeration |
| sensors | thermal breakdown (fans arrive with the base snapshot) |

Lifecycle:

| Event | Action |
|---|---|
| `onAppear` | `metrics.applySamplingSettings(...)`, `metrics.retain()`, `dashboard.attach(to: metrics)`, `dashboard.activate(section)` |
| section change | `dashboard.activate(newSection)` — cancels in-flight work via `generation`, starts the new probe set |
| settings change | `metrics.applySamplingSettings(...)` |
| `onDisappear` | `dashboard.deactivate()`, `metrics.release()` |

`SettingsContentView` only builds `DashboardView` for `pane == .dashboard`, so opening
Settings on Overview constructs no service and starts no timer. Overview keeps reading the
cached snapshot exactly as it does today.

### `SystemMetricsService.historyCapacity`: static → instance

Currently `static let historyCapacity = 48`, referenced by `StatusTabView` when building the
chart. The dashboard chart is ~4× wider and needs a denser series. Change to an instance
`let historyCapacity: Int` with an `init(historyCapacity: Int = 48)` default, keeping the
static as that default so existing test references still resolve. `StatusTabView` switches
to `metrics.historyCapacity`. Popover behaviour is unchanged.

## 5. Deep link: card → tab

```
StatusBarController.showSettingsWindow(initialPane:dashboardSection:)
        ▲
StatusPopoverView(openDashboard:)  ──▶ StatusTabView ──▶ SystemMetricsCards
        │
SettingsWindowView(initialPane:initialDashboardSection:) ──▶ DashboardView(initialSection:)
```

`MetricDetailTarget → DashboardSection` is a pure function on `DashboardSection`
(`init(target:)`), unit-tested for total coverage of `MetricDetailTarget.allCases`:
cpu→cpu, memory→memory, disk→storage, network→network, fan→sensors.

Repeat deep-linking works because `showSettingsWindow` already rebuilds the
`NSHostingController` on every call and reassigns `window.contentViewController`, so a fresh
`SettingsWindowView` is constructed with the new initial pane and section each time. No
extra state plumbing needed — this is verified behaviour of the existing code path
(`StatusBarController.swift:505`), not an assumption.

**Card interaction.** The existing `metricDetailSource(_:service:)` modifier gains an
optional `open:` closure. Hover anchoring and the `onHover` ownership rule are untouched;
the card body is wrapped in a `Button` with `PressableButtonStyle` (already the project's
tappable-tile idiom) plus `.contentShape(Rectangle())`, `.accessibilityHint`, and
`.help(...)`. Keeping both behaviours in one modifier prevents a card from ever having hover
detail without its matching link.

`MetricDetailPanel` gains a footer hint line so the click target is discoverable rather than
hidden.

## 6. Chart reuse

`CPUUsageChart` is currently `private` inside `StatusTabView.swift` and the dashboard needs
the same stacked user/system band. Move it — unchanged in behaviour — into a new
`MetricCharts.swift` alongside a new general `SeriesChart`:

```swift
struct SeriesChart: View {
  let series: [ChartSeries]      // 1–2 bands: values + tint + label
  let capacity: Int
  let upperBound: Double?        // nil = autoscale to the window maximum
}
```

`SeriesChart` covers GPU utilization (bound 1.0), disk read/write (autoscale, 2 series),
network down/up (autoscale, 2 series), and fan RPM (bound = `maxRPM`). Both charts share
`Canvas`, the rounded baseline fill, and the "a single sample draws flat across the width"
rule, so a freshly opened tab never shows an empty box.

## 7. View composition

```
DashboardView
  VStack(spacing: 0)
    SettingsPaneHeader(.dashboard)     // reused
    DashboardTabBar(selection:)        // same idiom as PopoverTabBar, window-scale
    Divider
    ScrollView { section content }     // per-section, scrolls independently
```

Content width is ≈510 pt (700 min window − ~190 sidebar), so sections use a 2-column `Grid`
of `DashboardCard`s with full-width cards for charts.

New components in `DashboardComponents.swift`: `DashboardCard`, `StatTile`, `DataRow`,
`DashboardTabBar`, `UnsupportedNote`. These are window-scale siblings of the popover's
`PopoverCard`/`MetricReadout` — the popover set is tuned for 360 pt and 9–11 pt type, so
reusing it directly would look undersized; the shared vocabulary is the tint/corner/material
language, which both follow.

Section views split across two files to keep each readable:
`DashboardComputeSections.swift` (CPU, GPU, Memory) and `DashboardIOSections.swift`
(Storage, Network, Sensors).

## 8. Unsupported states

`UnsupportedNote` renders an explicit sentence wherever a Mac cannot report something —
never a zero, per PRD R4:

| Condition | Message |
|---|---|
| `gpu.isEmpty` | "This Mac reports no GPU performance counters." |
| `fans.isEmpty` | "This Mac has no fans." |
| `thermals.isEmpty` | "No temperature sensors reported." |
| `swap.total == 0` | "Swap is not in use." |
| `pressure == nil` | "Pressure level unavailable." |
| cluster partition mismatch | cores render unlabelled |

## 9. Compatibility & risk

| Risk | Mitigation |
|---|---|
| Popover regression from shared-code edits | `CPUUsageChart` moves verbatim; `historyCapacity` keeps its 48 default; `metricDetailSource` gains an *optional* parameter |
| Two `SystemMetricsService` instances both writing the cache | Only one is ever live — `showSettingsWindow` closes the popover first. Both write valid snapshots, so a race is benign (last writer wins). |
| Stale probe result landing after a tab switch | `generation` counter guard, mirroring `SystemDetailService` |
| Volume list includes DMG/NFS mounts (observed on this Mac) | `.skipHiddenVolumes` + `volumeIsBrowsable`; internal volumes sort first and are badged |
| Virtual `en*` interfaces with zero traffic (10 observed) | Interface list requires `IFF_UP`, non-loopback, and either an IPv4 address or nonzero traffic; reuses the existing `isCountableInterface` prefix filter |
| `getloadavg` on a saturated machine reads > core count | Correct behaviour; shown as a raw figure next to core count for context |

## 10. Rollout / rollback

Additive. No persisted schema change, no settings migration, no entitlement change (the app
is not sandboxed — `Resources/MenuCue.entitlements` carries only the iCloud KV identifier —
so `proc_listallpids`, volume enumeration, and IOKit all work as verified).

Rollback = revert the commit. The only edits to existing behaviour are the memory panel's
process limit (6→3) and the `historyCapacity` static→instance change; both are single-line
reversions.

## 11. Test plan

Pure logic, unit-testable without a live system:

- `SystemDetailProbe.rank(_:limit:)` honours limit 3 and 10, and still folds `" Helper"` names.
- `DashboardSection(target:)` covers every `MetricDetailTarget.allCases` case.
- `SettingsPane.allCases.first == .dashboard`.
- `SystemMetricsProbe.perCoreLoad(from:to:)` — delta math, zero-delta and wraparound return `nil`.
- `MetricHistory.append` — ring capacity, oldest-dropped ordering.
- `MemoryPressureLevel.decode` — 1/2/4 map, everything else `nil`.
- `CoreCluster` partitioning — correct split, and `unspecified` when counts don't cover the core count.
- `SwapUsage.fraction` — zero total does not divide by zero.
- `SystemMetricsService(historyCapacity:)` — default stays 48; custom capacity trims correctly.

Live verification (manual, on this Mac) is enumerated in `implement.md`.
