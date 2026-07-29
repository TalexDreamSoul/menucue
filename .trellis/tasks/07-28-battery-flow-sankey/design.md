# Design — Battery flow Sankey card

## Data layer

### New model (`PowerDiagnostics.swift`)

```swift
/// Live power-path telemetry from AppleSmartBattery. All fields optional because
/// availability differs by hardware (PowerTelemetryData is Apple-Silicon-only).
struct PowerTelemetry: Equatable, Codable {
  var adapterRatedWatts: Int?    // AdapterDetails.Watts (0/absent when unplugged)
  var systemInWatts: Double?     // PowerTelemetryData.SystemPowerIn, mW → W
  var systemLoadWatts: Double?   // PowerTelemetryData.SystemLoad, mW → W
}
```

`BatteryStatus` gains `var telemetry: PowerTelemetry?` (optional with nil default so any
decoder of old payloads keeps working). Battery branch watts stay on the existing
`flow.watts` (signed InstantAmperage × Voltage) — sign convention proven by the current
parser; telemetry's `BatteryPower` field is NOT used (sign semantics unverified).

### Parser

`PowerDiagnosticsParser.parsePowerTelemetry(_ text: String) -> PowerTelemetry?`

The existing `signed()` regex deliberately matches only bare top-level scalar lines.
Adapter/telemetry values live inside single-line inline dicts, so a second helper is
needed:

- Anchor the top-level key line: `^[\s|+\-]*"AdapterDetails" = \{(.*)$` (top-level dict
  properties end the anchoring problem the file header comment describes; the
  same-name key inside `AppleRawAdapterDetails` is on a *different* top-level line, so
  line-anchoring on the exact property name avoids it).
- Within that captured payload, match `"Watts"=(\d+)`.
- Same approach for `"PowerTelemetryData" = \{...\}` payload with
  `"SystemPowerIn"=(\d+)` and `"SystemLoad"=(\d+)` (mW; divide by 1000).
- Return nil only when *nothing* useful was found; individual fields stay optional.
- Unplugged AdapterDetails can be `{}` or carry `Watts=0` — map 0/absent to nil.

Probe change (`PowerDiagnosticsProbe.swift` `batteryStatus()`): reuse the already-captured
ioreg output — `let telemetry = registry.flatMap { PowerDiagnosticsParser.parsePowerTelemetry($0.standardOutput) }`.
No new subprocess.

## Flow-state classification

```swift
enum PowerFlowState: Equatable {
  case charging(adapterW: Double, batteryW: Double, systemW: Double, ratedW: Int?)
  case directSupply(systemW: Double, ratedW: Int?)
  case batteryAssist(adapterW: Double, batteryW: Double, systemW: Double, ratedW: Int?)
  case onBattery(dischargeW: Double)
}
```

Free function `PowerFlowState.make(battery: BatteryStatus) -> PowerFlowState?` — nil when
telemetry insufficient (drives the R4 fallback). Classification:

- `isOnAC == false` → `.onBattery(|flow.watts|)` (needs only flow; telemetry not
  required, but ribbon still renders — battery → laptop uses flow.watts alone).
  When `flow.watts ≥ −0.05` (idle/sleep edge) show it as 0.0 W ribbon rather than nil.
- `isOnAC == true` → requires `systemLoadWatts` (else nil → fallback):
  - `flow.watts > +0.5` → `.charging(batteryW: flow.watts, systemW: systemLoad, …)`
  - `flow.watts < −0.5` → `.batteryAssist(adapterW: systemIn ?? max(0, systemLoad − |batteryW|), …)`
  - else → `.directSupply(systemW: systemIn ?? systemLoad, …)`

Threshold ±0.5 W keeps trickle noise from flapping between layouts; the 5 s cadence plus
`PopoverMotion.value` animation smooths label changes.

## View (`PowerFlowView.swift`, new file)

### Layout

Fixed-height (≈96 pt) HStack-free custom layout inside GeometryReader:

- Node chips are rounded rects (`RoundedRectangle(cornerRadius: 10, continuous)`), fill
  `Color.primary.opacity(0.06)`, width 44 pt; sources column at leading edge, sinks at
  trailing. A single node in a column spans full height; two nodes split height
  proportionally to their watts (min 28 pt each) with 6 pt gap — matching the AlDente
  reference where node height tracks ribbon thickness.
- Node content: SF Symbol (`powerplug.fill` / `laptopcomputer` /
  `battery.100percent.bolt` when charging, `battery.75percent` otherwise) plus, on the
  plug node, the rated watts caption ("140W") when known.
- Ribbons occupy the span between columns. A ribbon from source edge (x0, y0±h0/2) to
  sink edge (x1, y1±h1/2) is a closed path of two cubic Béziers (top edge, bottom edge)
  with control points at horizontal midpoint — the classic Sankey S-curve. End
  thicknesses h0/h1 are each end's share of that node's watts mapped to node height
  (min 12 pt so labels fit).
- Wattage label (`String(format: "%.2f W")`) centered on each ribbon at midX,
  `.system(size: 11–13, weight: .semibold, design: .rounded)`, monospacedDigit,
  `.contentTransition(.numericText())`.

### Ribbon fill

LinearGradient along x: `[tint.opacity(0.10) @0, tint.opacity(0.85) @0.42,
tint.opacity(0.18) @0.75, tint.opacity(0.10) @1]` — reproduces the AlDente "hot spot
left of center". Tint by energy source: adapter-fed ribbons amber/yellow
(`Color(hue: 0.13, …)`), battery-fed ribbons green — consistent with the card's existing
green-charge / orange-discharge readouts (battery-assist ribbon may use orange-leaning
green; final pick during implementation, single constant).

Shimmer (flow direction cue): a TimelineView-driven phase slides the bright stop slowly
toward the sinks (~6 s period). Disabled under `accessibilityReduceMotion`; static
gradient otherwise identical.

### Accessibility

The whole flow view is one accessibility element,
`.accessibilityLabel(L10n…)` describing state + numbers, e.g. "Adapter supplying 83.5 W
to system and 17.0 W to battery".

## Card integration (`PowerTabView.swift` batteryCard)

```
header row (unchanged)
if let state = PowerFlowState.make(battery) → PowerFlowView(state:)
else → MetricBar (unchanged fallback)
readout row (unchanged)
```

## Localization

New keys (en + zh-Hans): "Adapter", "System" node help/accessibility strings, state
sentences for accessibility. Existing keys reused for Battery. zh-Hans: 适配器 / 系统.

## Testing

- `PowerDiagnosticsTests`: `parsePowerTelemetry` against a trimmed real ioreg fixture
  (from this machine, includes AppleRawAdapterDetails decoy line), an unplugged fixture
  (AdapterDetails={}, no PowerTelemetryData), and a garbage fixture → nil.
- `PowerFlowState.make` classification table tests (charging / direct / assist /
  on-battery / missing-telemetry-fallback).
- Localization coverage tests pick up new keys automatically.

## Rollback

Purely additive: new struct + optional field + new view file + one branch in
batteryCard. Reverting = dropping the branch; fallback path is the current UI, kept
compiling at all times.
