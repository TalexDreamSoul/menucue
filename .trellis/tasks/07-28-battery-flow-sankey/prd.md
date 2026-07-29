# Battery flow card: AlDente-style split power flow

## Goal

Replace the flat progress-bar presentation in the popover's "Battery Flow" card with an
AlDente-Pro-style Sankey flow: power ribbons flowing between an adapter node, a battery
node, and a laptop (system) node, with ribbon thickness proportional to watts and a warm
glowing gradient along the flow direction.

Reference screenshots (user-provided):
- Charging split: plug node (rated "100W") on the left; two ribbons out — thin one
  (17.01 W) into a battery node top-right, thick one (83.48 W) into a laptop node
  bottom-right.
- Direct supply: single ribbon plug → laptop with centered wattage (103.30 W).

## Requirements

- R1. The card renders one of four flow states, chosen from live data:
  - **Charging** (AC, battery watts > +0.5 W): plug → {battery, laptop} split.
  - **Direct supply** (AC, |battery watts| ≤ 0.5 W): plug → laptop single ribbon.
  - **Battery assist** (AC, battery watts < −0.5 W): {plug, battery} → laptop merge.
  - **On battery** (no AC): battery → laptop single ribbon.
- R2. Ribbon thickness scales with watts within the state (minimum readable thickness);
  each ribbon carries its wattage label; the plug node shows the adapter's rated watts.
- R3. Data comes from the `ioreg -rn AppleSmartBattery` read the probe already performs —
  no new subprocess or polling cadence. New fields: `AdapterDetails.Watts` (rated),
  `PowerTelemetryData.SystemPowerIn` / `SystemLoad` (mW). Battery branch watts reuse the
  existing `InstantAmperage × Voltage` value.
- R4. Graceful degradation: when telemetry fields are absent (Intel Macs, desktops,
  parse failure), the card keeps today's layout (MetricBar + readouts) unchanged.
- R5. Existing card content that stays: header row (percentage + power source +
  charging state), bottom readout row (battery flow W, rate %/h). The green MetricBar is
  replaced by the flow view when telemetry is available.
- R6. All new user-visible strings localized in en + zh-Hans; flow view has
  accessibility labels describing the state and wattages.
- R7. Visual language matches the popover system: PopoverMetrics radii/spacing,
  PopoverMotion animations, numericText transitions for wattage labels. Shimmer or
  glow animation must respect `accessibilityReduceMotion`.
- R8. (Added 2026-07-28 mid-task) The card header's top-right stack shows an estimated
  runtime ("预估续航") while the battery is actually draining. The figure must read
  slightly conservative: take the more pessimistic of macOS's time-to-empty and the
  linear percentage/rate projection, then apply a further ~10% haircut. Hidden while
  charging, while drain is negligible, or when the estimate exceeds 24 h (idle noise).

## Constraints

- Popover card content width is ~312 pt (360 popover − 2×14 content padding − 2×10 card
  padding); flow view height budget ≤ ~120 pt so the Power tab still fits its cards.
- 5-second refresh cadence (existing battery timer); values animate between samples.
- No new permissions, no helper involvement, no new processes.

## Acceptance Criteria

- [ ] On this dev machine (M-series, 140W adapter): charging shows a split flow whose
      battery + laptop labels track ioreg values; idle-on-AC shows single plug → laptop
      ribbon; unplugging shows battery → laptop.
- [x] Battery-assist state renders {plug, battery} → laptop when system draw exceeds
      adapter delivery (verifiable by simulated snapshot in a preview/test harness).
- [x] With telemetry absent (unit-tested via parser + a fixture without
      PowerTelemetryData), card falls back to the current MetricBar layout.
- [x] Parser unit tests cover: full telemetry sample, missing adapter (on battery),
      missing telemetry dict, zero/negative battery watts state classification.
- [x] `swift build` and `swift test` pass; localization coverage tests pass with the new
      strings.
- [x] Conservative runtime estimate (R8): unit tests cover haircut math, min-of-sources,
      charging/idle/absurd-value suppression; line renders in the header's trailing
      stack only when an estimate exists.
