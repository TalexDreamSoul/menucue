# Animation quality and status performance optimization

## Goal

Reduce MenuCue's sustained CPU and unnecessary rendering while live metrics are visible, and give users one clear animation-quality control with three presets: Full, Elegant, and Minimal.

## Background

- The supplied profile shows the status surface holding roughly 46% CPU while visible, with SwiftUI updates, CoreGraphics text drawing, RenderBox/off-screen animation work, and repeated Canvas redraws dominating the main thread.
- System probes run primarily on a utility queue. Sensor IPC has measurable cost, but the evidence does not identify it as the source of the sustained main-thread load.
- Status sampling currently publishes the full snapshot and CPU history separately, so one successful sample can invalidate the same observed SwiftUI tree multiple times.
- Status sampling is released only from SwiftUI `onDisappear`, while the retained `NSPopover` already exposes an authoritative `PopoverPresentationState`. Closing the popover may therefore leave Status sampling active.
- The app already has separate machine-local sampling settings. Animation quality must not silently change their interval or data freshness.

## Requirements

### R1. User-facing animation quality

- Add one three-option control named **Animation effects** to the existing Appearance settings pane.
- Options are **Full**, **Elegant**, and **Minimal**; the corresponding Simplified Chinese labels are **极致**, **优雅**, and **简约**.
- Use a segmented picker and apply changes immediately without relaunching.
- Persist the choice locally on this Mac. Do not include it in iCloud `PortableSettingField` synchronization.
- Product default: **Elegant**.

### R2. Preset behavior

- **Full** preserves the complete visual treatment: spatial navigation, matched-geometry selection, symbol feedback, sampled-value transitions, animated bars, hover/press motion, and visible-only Power Flow shimmer.
- **Elegant** keeps concise navigation and interaction feedback, animates only primary live values and bars, removes secondary numeric rolling, reduces decorative symbol/scale motion, and lowers continuous animation cadence.
- **Minimal** removes sampled-value rolling, bar interpolation, spatial page travel, spring/scale decoration, and continuous animation. It may retain a short opacity transition and immediate state feedback.
- The preset must apply consistently to the popover, Dashboard, Settings navigation, Power Flow, shared controls, and menu-bar clock transition.

### R3. Accessibility override

- macOS Reduce Motion always overrides the selected preset.
- Under Reduce Motion, disable spatial movement, numeric rolling, symbol bounce, spring/scale decoration, and continuous shimmer. At most, retain a short opacity transition.
- Changing the user preset must not weaken the system accessibility preference.

### R4. Sampling lifecycle

- Status metrics and hover detail probes run only while the popover is visible and the Status tab is active.
- Closing the popover, leaving the Status tab, or destroying the view must release sampling exactly once and clear hover detail state.
- Reopening the popover must resume sampling exactly once.

### R5. Rendering and probe efficiency

- Publish the status snapshot and matching CPU history as one coherent display frame per successful sample.
- Avoid publishing an unchanged power-source value.
- Cache disk-capacity metadata for 30-60 seconds while keeping CPU, disk-throughput, and network rates on the configured sampling interval.
- Refresh fan and temperature readings by elapsed time, with a recommended 10-second interval, instead of coupling them to every N samples.
- Reuse precomputed point arrays when drawing CPU chart fill and stroke paths.
- Preserve current formatting, cache restore behavior, history capacity, adaptive sampling behavior, and displayed metric semantics.

### R6. Compatibility and localization

- Preserve the macOS 13 deployment floor.
- Add English and Simplified Chinese localization entries for the control, preset names, and these selected-option descriptions: Full uses complete motion, Elegant keeps essential feedback with lower rendering cost, and Minimal removes continuous and spatial motion.
- Keep the Picker's visible label available to VoiceOver and expose the selected option's description as accessibility help.
- Invalid or unknown stored animation values fall back to Elegant without affecting neighboring settings.

## Acceptance Criteria

- [ ] The Appearance pane exposes a segmented Full / Elegant / Minimal picker and applies the selected profile immediately.
- [ ] The selected preset survives app restart, corrupt or unknown stored values fall back to Elegant, and the field is absent from iCloud portable settings.
- [ ] Each preset follows the behavior matrix in the technical design across all in-scope surfaces.
- [ ] The Animation effects picker has a meaningful VoiceOver label, each option is announced by name, and the selected description is available as accessibility help.
- [ ] Reduce Motion forces the reduced profile regardless of the stored preset.
- [ ] After `popoverDidClose`, at most one in-flight status sample may finish; no further status probe starts while hidden.
- [ ] Repeated show/hide and tab-switch cycles do not over-retain or over-release samplers.
- [ ] One successful system-metrics sample emits no more than one display-frame publication, including after history reaches capacity.
- [ ] Disk-capacity metadata respects its TTL while throughput and network rates continue at the configured interval.
- [ ] CPU chart output remains visually equivalent while each band computes its points once per draw.
- [ ] Existing focused tests pass on macOS 13-compatible code paths.
- [ ] In three 120-second Release-build traces on the same plugged-in Mac as the baseline, after a 15-second warm-up, Elegant's median average CPU is at least 30% lower than the freshly captured pre-change baseline; Minimal has no continuous Timeline/DisplayLink work between samples.
- [ ] Across at least 50 signposted main-thread sample commits from those traces, p95 remains below 8 ms and no commit exceeds 16.7 ms.

## Out of Scope

- Changing adaptive sampling intervals based on animation quality.
- Redesigning metric cards or changing the set of displayed metrics.
- Replacing SwiftUI Canvas or the sensor backend.
- Optimizing the permanent menu-bar clock's one-second timer and date-capsule cache beyond making its transition honor the selected animation preset.
