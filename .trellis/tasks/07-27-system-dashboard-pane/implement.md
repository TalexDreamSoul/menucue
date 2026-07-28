# Implementation Plan — System Dashboard pane

Ordered so the tree builds and the app runs after **every** step. Each step lists its own
validation. Do not batch steps past a review gate.

Baseline: `swift build` passes on a clean tree (verified before planning).

---

## Step 1 — Memory panel shows three processes  ▸ PRD R1

- `SystemDetailProbe.topMemoryProcesses(limit:)` default `6` → `3`.
- `SystemDetailService.init` gains `processLimit: Int = 3`, stored and passed to the probe.
  The Dashboard later constructs its own service with `processLimit: 10`.
- Test: `rank` honours limit 3 and 10 and still folds `" Helper"` suffixes.

**Validate:** `swift test --filter SystemDetail` · run app, hover the Memory card → 3 rows.
**Rollback point:** self-contained; revert this file pair alone.

---

## Step 2 — Probe layer  ▸ PRD R4

New `Sources/MenuCue/DashboardProbe.swift` + additions to `SystemMetricsProbe`:

| Function | Interface |
|---|---|
| `perCoreTicks() -> [CPUTicks]` | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` — **must** `vm_deallocate` the returned array |
| `perCoreLoad(from:to:) -> [CPULoadSample]?` | element-wise delta; `nil` on zero/wrapped delta, mirroring `cpuLoad(from:to:)` |
| `coreTopology() -> [CoreCluster]` | `IOPlatformDevice` → `cluster-type` + `logical-cpu-id`; fallback to `hw.nperflevels` walked in reverse; `unspecified` if the partition does not cover the core count |
| `loadAverage() -> LoadAverage?` | `getloadavg` |
| `swapUsage() -> SwapUsage?` | `sysctlbyname("vm.swapusage")` → `xsw_usage` |
| `memoryPressure() -> MemoryPressureLevel?` | `sysctlbyname("kern.memorystatus_vm_pressure_level")` |
| `mountedVolumes() -> [VolumeUsage]` | `FileManager.mountedVolumeURLs` + format/internal/browsable keys |
| `networkInterfaces() -> [NetworkInterfaceInfo]` | `getifaddrs`; AF_LINK for MAC + counters, AF_INET for IPv4; reuse `isCountableInterface`; keep only UP interfaces with an IP **or** nonzero traffic |
| `diskOperationCounters()` | extend the existing `IOBlockStorageDriver` walk to also sum `Operations (Read|Write)` |

Every function returns `nil`/empty on failure — never a zero that reads as a measurement.

**Validate:** `swift build`. Write a temporary `main`-style XCTest that prints each reading
and assert only on shape (non-negative, core count == `hw.logicalcpu`), so the suite stays
deterministic on other hardware.

**Watch:** `host_processor_info` leaks the array if `vm_deallocate` is skipped — this runs
every 2 s while the CPU tab is open, so a leak here is not theoretical.

---

## Step 3 — Models  ▸ PRD R3, R4

New `Sources/MenuCue/DashboardModels.swift` with the types in `design.md §3`.
Foundation only — no `Color`, no SwiftUI.

Includes `DashboardSection.init(target: MetricDetailTarget)` and `MetricHistory`.

**Validate:** `swift test` with new cases: `DashboardSection(target:)` totality over
`MetricDetailTarget.allCases`, `MetricHistory` ring behaviour, `MemoryPressureLevel.decode`
(1/2/4 → level, everything else `nil`), `SwapUsage.fraction` zero-total safety,
`CoreCluster` partitioning incl. the mismatch → `unspecified` path.

---

## Step 4 — `DashboardMetricsService`  ▸ PRD R5

New `Sources/MenuCue/DashboardMetricsService.swift`.

- `attach(to: SystemMetricsService)` — Combine subscription on `$snapshot` appending disk
  r/w, net down/up, and fan RPM into `MetricHistory` buffers. Histories fill for **all**
  sections; only probes are gated.
- `activate(_ section: DashboardSection)` / `deactivate()` — 2 s timer on `.common` run-loop
  mode, probes dispatched to a utility queue, `generation` counter discards late results.
- Per-section probe sets exactly as tabled in `design.md §4`.
- `deinit` invalidates the timer and cancels the subscription.

Also in this step: `SystemMetricsService.historyCapacity` static → instance
(`init(historyCapacity: Int = 48)`, static retained as the default); update
`StatusTabView`'s chart call site to `metrics.historyCapacity`.

**Validate:** `swift test` — default capacity is still 48; a custom capacity trims correctly.
`swift build`; run the app and confirm the popover chart is visually unchanged.
**Review gate:** popover must be byte-for-byte behaviourally identical here. If the chart
shifts, stop and re-check the capacity plumbing before continuing.

---

## Step 5 — Chart + component vocabulary

- New `Sources/MenuCue/MetricCharts.swift`: `CPUUsageChart` **moved verbatim** from
  `StatusTabView.swift` (drop `private`), plus the new `SeriesChart` (`design.md §6`).
- New `Sources/MenuCue/DashboardComponents.swift`: `DashboardCard`, `StatTile`, `DataRow`,
  `DashboardTabBar`, `UnsupportedNote`.

**Validate:** `swift build`; popover CPU chart unchanged on screen.

---

## Step 6 — Dashboard pane shell  ▸ PRD R3

- `SettingsPane` gains `case dashboard`, **declared first** so `allCases` puts it at the top
  of the sidebar; add title / subtitle / `systemImage`.
- `SettingsContentView` special-cases `.dashboard`: render `DashboardView` directly instead
  of the shared `ScrollView` + 28 pt padding wrapper, so the tab bar can pin.
- `SettingsWindowView` gains `initialDashboardSection: DashboardSection = .cpu`.
- New `Sources/MenuCue/DashboardView.swift` — shell + `@StateObject` services + the
  lifecycle table from `design.md §4`.

Stub each section with its title card first; fill content in Step 7.

**Validate:** `swift test --filter SettingsPane` (dashboard is first). Run the app → sidebar
shows Dashboard on top, tabs switch, **Overview still starts no timer**.

---

## Step 7 — Section content  ▸ PRD R4

`DashboardComputeSections.swift` (CPU, GPU, Memory) and `DashboardIOSections.swift`
(Storage, Network, Sensors). Content per the PRD R4 table; unsupported states per
`design.md §8`.

**Validate:** run the app and walk all six tabs. Every row in the R4 table is either
populated with a live value or shows an explicit unsupported note. Cross-check a few figures
against Activity Monitor (memory used, swap, volume capacity) and `ifconfig en0` (MAC, IPv4).

---

## Step 8 — Deep link  ▸ PRD R2

- `metricDetailSource(_:service:open:)` — optional `open` closure; wrap in `Button` +
  `PressableButtonStyle` + `.contentShape` + `.accessibilityHint` + `.help`.
- `MetricDetailPanel` footer hint line.
- `SystemMetricsCards` and `StatusTabView` thread an `openDashboard: (DashboardSection) -> Void`.
- `StatusPopoverView` gains the same parameter.
- `StatusBarController.showSettingsWindow(initialPane:dashboardSection:)`; wire
  `openDashboard` when constructing `StatusPopoverView`.

**Validate:** click each of the five cards → correct tab. Click a card, close, click a
different card → correct tab (guards against the reused-window path). Click a card while
Settings is already open on another pane → jumps to Dashboard on the right tab. Hover detail
still works and the hover panel still anchors correctly.

---

## Step 9 — Quality pass  ▸ PRD acceptance

1. `swift build 2>&1 | grep -i warning` — no new warnings.
2. `swift test` — full suite green.
3. Battery/cost check: open Dashboard, switch through all tabs, close the window; confirm
   via Activity Monitor that MenuCue returns to its idle CPU baseline (no orphaned timer).
4. Fanless/no-GPU path: exercise the `fans.isEmpty` and `gpu.isEmpty` branches (temporarily
   force-empty the readings) and confirm the notes render instead of empty cards.
5. Re-read PRD acceptance criteria one by one and tick them off.
6. Dispatch `trellis-check` for a full-scope review against `prd.md` + `design.md`.

---

## Rollback points

| After step | Reverting gives back |
|---|---|
| 1 | Six-process memory panel |
| 4 | Static `historyCapacity`; no service |
| 8 | Dashboard exists but is only reachable from the sidebar |

Everything is additive apart from Step 1's limit and Step 4's static→instance change; both
are single-line reversions. No persisted schema, settings, or entitlement changes.

## Validation commands

```bash
swift build
swift test
swift test --filter Dashboard
scripts/build-app.sh    # only if packaging needs a check; not required for this task
```
