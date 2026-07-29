# Implementation plan — Battery flow Sankey card

## Ordered checklist

1. [x] **Parser + model** (`Sources/MenuCue/PowerDiagnostics.swift`)
   - Add `PowerTelemetry` struct; add `telemetry: PowerTelemetry?` to `BatteryStatus`
     (locate its definition first; keep default nil).
   - Add `PowerDiagnosticsParser.parsePowerTelemetry(_:)` (inline-dict payload
     matcher per design.md).
   - Add `PowerFlowState` enum + `make(battery:)` classifier (same file, near
     BatteryFlow).
2. [x] **Probe** (`Sources/MenuCue/PowerDiagnosticsProbe.swift`)
   - Populate `telemetry:` in `batteryStatus()` from the existing registry output.
3. [x] **Tests first-run** (`Tests/MenuCueTests/PowerDiagnosticsTests.swift`)
   - Fixtures: full telemetry (real trimmed sample incl. AppleRawAdapterDetails decoy),
     unplugged, missing telemetry.
   - Classifier table tests. Run `swift test --filter PowerDiagnostics`.
4. [x] **View** (`Sources/MenuCue/PowerFlowView.swift`, new)
   - `PowerFlowView(state: PowerFlowState)`: node chips, Sankey ribbons (two-Bézier
     closed path), gradient fill, wattage labels, shimmer behind
     `accessibilityReduceMotion`, accessibility label.
5. [x] **Integration** (`Sources/MenuCue/PowerTabView.swift` `batteryCard`)
   - Insert flow view branch; MetricBar stays as the nil-state fallback.
6. [x] **Localization** (`Sources/MenuCue/Resources/{en,zh-Hans}.lproj/Localizable.strings`)
   - Add node/accessibility strings both locales.
7. [x] **Full validation**
   - `swift build && swift test`
   - Manual: run app, open popover Power tab, verify current machine state renders
     (AC direct-supply or charging depending on moment); pull the plug → on-battery
     ribbon; replug → charging/direct.

## Validation commands

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -20
```

## Review gates

- After step 3: parser green before any UI work.
- After step 7: screenshot the card in at least two live states for the wrap-up.

## Rollback points

- Steps 1–3 are inert without step 5; revert = drop the `batteryCard` branch.
