# Implementation Plan

## Phase 0: Reproducible baseline and lifecycle correctness

- [x] Add `os_signpost`/`OSSignposter` intervals for utility sampling and main-thread frame commit.
- [x] Record hardware, macOS version, commit, Release configuration and fixed test conditions.
- [ ] Capture a five-minute closed-popover lifecycle soak plus three 120-second baseline traces after a 15-second warm-up for Status at 1.5 seconds, Status at 0.5 seconds, CPU hover, Memory hover, Power Flow and Dashboard.
- [x] Make `StatusTabView` consume authoritative popover visibility and idempotently retain/release `SystemMetricsService`.
- [x] Clear `SystemDetailService` target when the popover hides or Status leaves the hierarchy.
- [x] Add lifecycle regression coverage for repeated show/hide and tab changes.
- [x] Verify no new status sample begins after `popoverDidClose` and no stale result publishes.

## Phase 1: Metrics publication and probe cost

- [x] Introduce `SystemMetricsDisplayFrame` and publish snapshot/history once per successful sample.
- [x] Preserve read-only `snapshot` / `cpuHistory` access or update consumers deliberately.
- [x] Update `DashboardMetricsService` to subscribe to the coherent frame stream.
- [x] Suppress unchanged power-source publications.
- [x] Add an injectable monotonic clock for metadata and sensor cadence tests.
- [x] Add a 60-second disk-capacity metadata cache with an injectable TTL.
- [x] Change fan/temperature refresh from sample-count coupling to a 10-second elapsed-time cadence.
- [x] Add tests for one publication, saturated history, disk TTL, sensor cadence, and settings reschedule behavior without real-time sleeps.

## Phase 2: Chart rendering and independent performance gate

- [x] Precompute CPU user and combined point arrays once per Canvas draw.
- [x] Build fill and stroke paths from those shared arrays.
- [x] Add deterministic path/point tests for empty, single, partial, and full-capacity history.
- [x] Verify fixed-fixture rendering remains visually equivalent.
- [ ] Repeat closed, Status and Dashboard traces before any motion migration.
- [ ] Record the independent reduction from lifecycle, publication, probe and chart changes; investigate if no material improvement is measurable.

## Phase 3: Motion preference and policy

- [x] Add `AnimationQuality` and machine-local `AppSettings.animationQuality`, defaulting to Elegant.
- [x] Persist `animationQuality.v1` in `SettingsStore`; add missing/corrupt/unknown fallback tests.
- [x] Prove the field is absent from `PortableSettingField` and iCloud envelopes.
- [x] Add the segmented Animation effects picker and selected-option description to the Appearance pane.
- [x] Preserve meaningful Picker/option VoiceOver labels and expose the selected description as accessibility help.
- [x] Add English and Simplified Chinese localization entries.
- [x] Implement `MotionProfile`, its environment key, and Reduce Motion override tests.
- [x] Inject the effective profile at popover and Settings roots.

## Phase 4: Migrate animation call sites

- [x] Classify every numeric/state call site as primary telemetry, secondary telemetry, bar, navigation/state, periodic time, or static using the design table.
- [x] Add profile-aware shared modifiers for primary/secondary numeric transitions.
- [x] Make `MetricBar`, `PressableButtonStyle`, card hover, shared tab bars, and symbol feedback consume the profile.
- [x] Migrate popover and Dashboard navigation transitions to spatial/crossfade/identity policy.
- [x] Migrate Quick Actions, metric detail panels, calendar navigation, sampled values, and Power values.
- [x] Make Power Flow cadence 20 FPS / 10 FPS / static for Full / Elegant / Minimal and pause it whenever hidden.
- [x] Make the menu-bar clock transition honor push / fade / none plus system Reduce Motion.
- [x] Run the complete source audit and classify every remaining match.

Audit command:

```bash
rg -n '\.animation\(|withAnimation\(|contentTransition\(|\.transition\(|matchedGeometryEffect\(|symbolEffect\(|menuCueSymbolBounce|TimelineView\(\.animation|CATransition|repeatForever|phaseAnimator|keyframeAnimator' Sources/MenuCue
```

## Phase 5: Verification

Run focused tests first:

```bash
swift test --filter SystemMetrics
swift test --filter MetricsSampling
swift test --filter SettingsStore
swift test --filter Localization
swift test --filter Dashboard
swift test --filter Popover
```

Then run the full gates:

```bash
swift test
swift build
```

Perform headless visual verification for Full, Elegant, Minimal, and Reduce Motion using the project's `ImageRenderer` pattern. Check popover Status, Power Flow, Dashboard, and Appearance settings at light/dark appearance. Use Accessibility Inspector or VoiceOver separately; `ImageRenderer` does not validate the accessibility tree.

Repeat the fixed Instruments protocol: same physical Mac, Release build, wall power, Low Power Mode off, 15-second warm-up, 120-second trace, three runs per scenario. Record:

- Closed-state sample count and wakeups.
- Median average CPU by preset.
- Signposted main-thread frame-commit count, p50, p95 and max from at least 50 commits.
- SwiftUI body update count per successful sample.
- Animation hitches over 16.7 ms.
- Continuous Timeline callbacks between samples.

## Review Gates

- [x] Product owner confirms 极致 = highest visual fidelity and 优雅 = default.
- [x] P0 lifecycle fix passes before any rendering optimization is accepted.
- [ ] Phase 2 performance gate isolates core data-path savings before motion changes.
- [x] Each successful metrics sample has at most one frame publication.
- [x] Reduce Motion overrides every profile category.
- [x] Animation quality never changes sampling intervals.
- [x] Every animation audit match is profile-controlled, a data timer, or explicitly documented as static.
- [ ] Elegant's three-run median average CPU is at least 30% below the freshly captured baseline.
- [ ] At least 50 signposted commits yield p95 below 8 ms and max no greater than 16.7 ms.
- [x] Minimal has no continuous animation callbacks between data/time ticks.
- [ ] Picker semantics and selected help text pass Accessibility Inspector/VoiceOver verification.
- [x] No macOS 14-only API is introduced without an availability fallback.
- [x] Full test and build gates pass.

## Verification Record

Completed on 2026-08-03:

- Environment: Apple M4 Pro, 48 GiB RAM, macOS 26.5 (25F71), source base `48ca8ce6f912c776b26ab7202c4d53d6549bc336`, Release configuration, AC power, system-reported `powermode=2`.
- `swift test`: 423 XCTest tests plus 5 Swift Testing tests passed.
- `swift build -c release`: passed.
- `git diff --check`: passed.
- Animation source audit: all remaining call sites route through `MotionProfile`, are profile-aware compatibility helpers, or are the static indeterminate-indicator fallback selected by policy.
- Headless light/dark render checks covered the animation-quality segmented control and all three Power Flow profiles; temporary render fixtures were removed after inspection.
- Two independent code-review passes found no unresolved production defects after lifecycle, disk-failure, reduced-motion indicator, actor-isolation, and segmented-control binding fixes.

Performance evidence remains pending. A smoke `xctrace` launch resolved to the already installed `/Applications/MenuCue.app` rather than this worktree's Release binary, so the trace was rejected and deleted. The fixed three-run baseline/after protocol and manual Accessibility Inspector/VoiceOver pass must be run against an isolated packaged build before the two corresponding gates can be closed.

## Risk and Rollback Points

- Checkpoint after Phase 0: lifecycle correctness can ship independently.
- Checkpoint after Phase 2: data-path optimization has its own measurements and can ship without motion settings.
- Checkpoint after Phase 3: persistence and profile resolution can be reverted without touching metrics data flow.
- Coherent frame publication changes Combine contracts; verify Dashboard before moving to motion migration.
- Keep sampling settings schema unchanged, so motion work can be rolled back without migration.
- If 10 FPS Power Flow appears visibly stepped, tune Elegant within 8-12 FPS; do not restore an unbounded Timeline.
