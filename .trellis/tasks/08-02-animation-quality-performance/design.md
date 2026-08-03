# Technical Design

## 1. Problem Model

The expensive path is not one probe. It is the multiplicative chain:

```text
Main-run-loop timer
  -> utility-queue system sample
  -> main-thread snapshot publication
  -> main-thread CPU-history publication
  -> parent + child ObservableObject invalidation
  -> string formatting + anchor preferences + numeric transitions + bars + Canvas redraw
```

The current implementation also relies on `StatusTabView.onDisappear` to stop sampling, even though `NSPopover` retains its content view after closing. `StatusBarController.popoverDidClose` already publishes the authoritative visibility state used by Power sampling and Power Flow.

The optimization therefore has four independent levers:

1. Correct visibility lifecycle.
2. One coherent published frame per sample.
3. Lower-frequency work for slow-changing metadata and sensors.
4. A semantic motion profile that controls animation categories, not only durations.

## 2. Motion Domain

### 2.1 Persisted setting

Add a local enum near other app presentation settings:

```swift
enum AnimationQuality: String, CaseIterable, Codable, Identifiable {
  case full
  case elegant
  case minimal
}
```

`AppSettings.animationQuality` defaults to `.elegant`. `SettingsStore` owns an `animationQuality.v1` raw-value key. This field is deliberately absent from `PortableSettingField` because device capability and accessibility preferences differ per Mac.

### 2.2 Effective profile

Replace the static-only `PopoverMotion` constants with an immutable environment value that resolves stored preference plus system accessibility:

```text
AnimationQuality + accessibilityReduceMotion
  -> MotionProfile
  -> category-specific modifiers and transitions
```

The profile exposes semantic decisions rather than leaking the raw enum into every view:

- `hoverAnimation`
- `pressAnimation`
- `stateAnimation`
- `navigationAnimation`
- `navigationTransition` (`spatial`, `crossfade`, `identity`)
- `numericTransitionPolicy` (`all`, `primaryOnly`, `none`)
- `barAnimation`
- `usesMatchedGeometry`
- `usesSymbolBounce`
- `continuousFrameInterval`
- `statusClockTransition` (`push`, `fade`, `none`)

Roots inject the effective value at `StatusPopoverView` and `SettingsWindowView`. `StatusBarController` resolves the same policy with `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` for AppKit/Core Animation.

### 2.3 Preset matrix

| Category | Full / 极致 | Elegant / 优雅 (default) | Minimal / 简约 | Reduce Motion override |
|---|---|---|---|---|
| Navigation | 260 ms move + fade | 180-220 ms short move + fade | 80-120 ms crossfade | 80-120 ms crossfade |
| Matched geometry | On | On | Off | Off |
| Symbol bounce | On | Off | Off | Off |
| Hover | Scale + color + stroke | Color/stroke, restrained scale | Immediate color/stroke | Immediate color/stroke |
| Press | Spring scale + opacity | Short ease scale + opacity | Immediate opacity | Immediate opacity |
| Primary sampled values | Numeric roll, 300 ms | Numeric roll, 140-180 ms | Immediate | Immediate |
| Secondary sampled values | Numeric roll, 300 ms | Immediate | Immediate | Immediate |
| Metric bars | 300 ms interpolation | 140-180 ms interpolation | Immediate | Immediate |
| Power Flow shimmer | 20 FPS while visible | 10 FPS while visible | Static | Static |
| Menu-bar clock change | 340 ms push | 160-200 ms fade | Immediate | Immediate |

A shared `menuCueNumericTransition(value:importance:)` modifier owns numeric-transition policy. Shared `MetricBar`, `PressableButtonStyle`, and symbol helpers consume the environment profile. Direct `withAnimation` and page-transition call sites consume the corresponding semantic property.

Numeric and state call sites are classified before implementation so Elegant does not depend on local judgment:

| Classification | Call sites | Elegant behavior |
|---|---|---|
| Primary live telemetry | Status CPU busy; Dashboard `StatTile`; Power Flow watt labels; explicitly marked headline power values | Short numeric transition |
| Secondary live telemetry | Temperature, fan RPM, CPU legend, `MetricReadout`, battery runtime, uptime, chart legends and detail rows | Immediate value update |
| Capacity/load bars | Shared `MetricBar` in Status, Dashboard, detail panels and fallback battery flow | Short interpolation |
| User-driven navigation/state | Calendar year/month, tab selection, quick-action count and feedback | Use navigation/state policy, never telemetry policy |
| Periodic time content | World clocks and uptime TimelineViews | Keep data tick; animate text only in Full |

Every migrated call site must be added to one row or explicitly documented as static.

Do not apply a global `transaction.disablesAnimations`: it would also suppress system presentation behavior and makes category-specific reduced-motion fallbacks impossible.

## 3. Settings UI

Add an **Animation effects** group to `SettingsPane.appearance`, below app appearance and above the system-appearance automation text. Use a segmented `Picker`, consistent with existing settings controls.

The control changes `AppSettings.animationQuality` through the existing `SettingsContentView.binding` / `AppModel.updateSettings` mutation boundary. No view reads or writes `UserDefaults` directly.

Appearance is the correct information-architecture owner. Overview remains responsible for machine state and sampling behavior, keeping visual quality independent from data freshness.

## 4. Sampling Lifecycle

`StatusTabView` observes `PopoverPresentationState.shared`, following the existing Power-tab pattern:

```text
onAppear + current visibility -> updateSampling
visibility change             -> updateSampling
onDisappear                   -> updateSampling(false)
```

A local `isSamplingActive` guard makes transitions idempotent. Starting applies the latest sampling settings and calls `metrics.retain()`. Stopping calls `metrics.release()` and `detail.hover(nil)`.

For testability, permit an injected `PopoverPresentationState` with `.shared` as the production default, or extract the idempotent start/stop gate into a small internal type. The chosen implementation must prove balanced retain/release behavior in tests.

This lifecycle correction is P0. Without it, closing a retained popover can leave sampling active and no animation preset can guarantee an idle hidden state.

## 5. Coherent Metrics Publication

Introduce an internal display frame:

```swift
struct SystemMetricsDisplayFrame: Equatable {
  var snapshot: SystemMetricsSnapshot
  var cpuHistory: [CPULoadSample]
}
```

`SystemMetricsService` publishes one `frame`. Read-only computed accessors may preserve the existing `snapshot` and `cpuHistory` call-site API. `finishSample` builds the next history locally, then assigns the complete frame once.

`DashboardMetricsService.attach(to:)` subscribes to `metrics.$frame.map(\.snapshot)` instead of `$snapshot`.

`powerSource` is assigned only when the probed value differs. `currentInterval` remains separately observable for tests and future UI but changes only when the resolved interval changes.

This design guarantees that the chart and headline values describe the same sample and caps the primary sample publication at one.

## 6. Probe Cadence

### Disk capacity

Cache `(name, used, total)` inside the utility-queue sampling state with a 60-second default TTL. Refresh it on first sample or expiry. Keep disk throughput counters in every sample because they require adjacent counter deltas.

Use an injected monotonic clock, defaulting to `ProcessInfo.processInfo.systemUptime`, for disk and sensor cadence. Tests advance this clock directly; they never wait 10 or 60 real seconds. `CumulativeCounters.timestamp` may be reused when the sample's counter provider is the authoritative monotonic source.

The local benchmark for the current volume-resource lookup produced a 0.002 ms median but a 124.6 ms maximum across 40 calls. The cache removes this long-tail work without reducing live throughput freshness.

### Sensors

Replace tick-count coupling (`sensorTickInterval`) with elapsed-time gating, default 10 seconds. Always include sensors on the first active sample, then carry the most recent readings between refreshes. This keeps behavior stable when the user changes sampling intervals.

### Network and counters

Keep CPU, memory, disk-throughput, and active-interface rates on the configured adaptive interval. They are the live data product and should not be coupled to visual quality.

## 7. Chart Rendering

`CPUUsageChart` currently recomputes the same band points for area fill and line stroke. Build `userPoints` and `combinedPoints` once inside the Canvas draw closure, then construct area and line paths from those arrays.

Keep the existing single-sample full-width rule, clipping, colors, line widths, accessibility behavior, and capacity semantics.

## 8. Scope of Motion Migration

Audit every existing animation call in `Sources/MenuCue` and map it to one semantic category. Current search surfaces animations in:

- `StatusPopoverView.swift`
- `PopoverComponents.swift`
- `StatusTabView.swift`
- `QuickActionViews.swift`
- `DashboardView.swift`
- `DashboardComponents.swift`
- `DashboardComputeSections.swift`
- `DashboardIOSections.swift`
- `PowerTabView.swift`
- `PowerFlowView.swift`
- `MetricDetailPanel.swift`
- `ViewCompatibility.swift`
- `StatusBarController.swift`

No direct spring, numeric transition, symbol effect, or continuous `TimelineView(.animation)` should bypass the effective profile after migration.

Periodic TimelineViews that exist to display time, such as clocks and uptime, continue ticking at their content resolution; only their transition animation changes. Data timers are not animations.

## 9. Compatibility and Failure Behavior

- macOS 13 remains supported.
- Unsupported SF Symbol effects continue degrading to a static symbol.
- Missing or corrupt stored animation quality resolves to Elegant.
- Unknown future values are ignored independently and do not invalidate all settings.
- If Reduce Motion changes while the app is running, SwiftUI roots recompute their effective profile immediately. AppKit status-clock transitions check the current system flag when applying a transition.
- In-flight samples may finish after hide, but generation/session checks prevent stale output from publishing and no follow-up work is scheduled.

## 10. Rollout and Measurement

Add `os_signpost`/`OSSignposter` intervals around the utility sample and the main-thread `finishSample` commit so Instruments can calculate sample count and commit duration rather than inferring them from stacks.

Use this fixed protocol for before/after traces:

- Same physical Mac as the supplied profile; record chip, memory, macOS version, commit and build configuration.
- Release build, no debugger, wall power, Low Power Mode off, same display state, and no foreground workload other than Instruments.
- Warm up for 15 seconds, then record 120 seconds per performance scenario, three runs per scenario. Separately run a five-minute closed-popover lifecycle soak to prove the sampler stays idle.
- Use 1.5-second sampling unless the scenario explicitly tests 0.5 or 10 seconds.
- Report the median of each run's average CPU. Compute commit p95/max from signposts with at least 50 commits across the three runs.

Capture these scenarios before any behavior change, after lifecycle/publication/chart optimization, and after motion migration:

1. Popover closed for five minutes.
2. Status visible at 1.5-second sampling with no hover.
3. Status CPU hover and Memory hover.
4. Status visible at 0.5-second and 10-second sampling.
5. Power Flow visible in all three presets.
6. Dashboard CPU and Storage sections.

Record Time Profiler, SwiftUI body updates, Animation Hitches, Energy Log, wakeups, average CPU, and signposted main-thread commit p95/max. Compare identical scenarios and keep the intermediate gate so core data-path savings are distinguishable from motion savings.

Roll back profile-specific visual changes independently if they regress UX. Lifecycle and coherent publication fixes remain valid regardless of preset tuning.
