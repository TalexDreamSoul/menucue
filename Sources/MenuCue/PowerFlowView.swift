import SwiftUI

/// AlDente-style power-path diagram for the Battery Flow card: ribbons between an
/// adapter node, a battery node, and the system node, with thickness tracking watts
/// and a warm gradient glowing along the flow direction. Rendered only when
/// `PowerFlowState.make` classified live telemetry; the card keeps its flat bar
/// otherwise.
struct PowerFlowView: View {
  let state: PowerFlowState

  @Environment(\.menuCueMotion) private var motion
  @ObservedObject private var popoverPresentation = PopoverPresentationState.shared

  private static let diagramHeight: CGFloat = 96
  private static let nodeWidth: CGFloat = 44
  private static let minimumRibbonThickness: CGFloat = 11
  private static let edgeInset: CGFloat = 4
  /// Split ribbons almost touch where they share a trunk edge…
  private static let trunkGap: CGFloat = 3
  /// …and only claim this share of the available height, so the pinned-apart far
  /// ends open a widening dark wedge between the streams — the split reading.
  private static let bandBudget: CGFloat = 0.8
  /// Chips are fixed-size and centered on their stream; thickness alone carries the
  /// wattage signal, and a band may stand taller than its chip (as in the reference).
  private static let plugChipHeight: CGFloat = 50
  private static let systemChipHeight: CGFloat = 44
  private static let batteryChipHeight: CGFloat = 36
  /// Minimum seam between two chips sharing a column when their streams pull the
  /// fixed-size cards together.
  private static let chipGap: CGFloat = 4
  /// Adapter-fed ribbons glow amber; battery-fed ribbons stay green — the same
  /// energy-source reading as the card's charge/discharge readout colors. Each pairs
  /// a saturated body tint with a paler high-brightness core: interpolating toward
  /// plain white grays the glow out on the dark card, so the core keeps the hue.
  enum RibbonPalette {
    case adapter
    case battery

    var tint: Color {
      switch self {
      case .adapter: return Color(hue: 0.12, saturation: 0.85, brightness: 1.0)
      case .battery: return Color(hue: 0.36, saturation: 0.72, brightness: 0.92)
      }
    }

    var core: Color {
      switch self {
      case .adapter: return Color(hue: 0.125, saturation: 0.42, brightness: 1.0)
      case .battery: return Color(hue: 0.36, saturation: 0.34, brightness: 0.98)
      }
    }
  }
  private static let shimmerPeriod: TimeInterval = 3

  var body: some View {
    Group {
      if let frameInterval = motion.continuousFrameInterval {
        // Paused while the popover is hidden: NSPopover keeps its content view
        // controller alive after close.
        TimelineView(
          .animation(
            minimumInterval: frameInterval,
            paused: !popoverPresentation.isVisible)
        ) { context in
          diagram(
            shimmerPhase: context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: Self.shimmerPeriod) / Self.shimmerPeriod)
        }
      } else {
        diagram(shimmerPhase: nil)
      }
    }
    .frame(height: Self.diagramHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  // MARK: - Composition

  private func diagram(shimmerPhase: Double?) -> some View {
    GeometryReader { proxy in
      let plan = plan(in: proxy.size)
      ZStack(alignment: .topLeading) {
        ForEach(plan.ribbons) { ribbon in
          let shape = RibbonShape(
            startX: ribbon.start.x, endX: ribbon.end.x,
            startY: ribbon.start.y, startThickness: ribbon.startThickness,
            endY: ribbon.end.y, endThickness: ribbon.endThickness)
          shape.fill(Self.gradient(for: ribbon.palette))
          if let shimmerPhase {
            shape.fill(Self.shimmer(phase: shimmerPhase, palette: ribbon.palette))
          }
        }
        ForEach(plan.nodes) { node in
          chip(for: node)
            .frame(width: node.frame.width, height: node.frame.height)
            .position(x: node.frame.midX, y: node.frame.midY)
        }
        ForEach(plan.ribbons) { ribbon in
          wattageLabel(ribbon.watts)
            .position(
              x: (ribbon.start.x + ribbon.end.x) / 2,
              y: (ribbon.start.y + ribbon.end.y) / 2)
        }
      }
      .animation(motion.barAnimation, value: state)
    }
  }

  private func chip(for node: FlowNode) -> some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(Color.primary.opacity(0.06))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.primary.opacity(0.07), lineWidth: 1)
      )
      .overlay(
        VStack(spacing: 2) {
          Image(systemName: node.symbol)
            .font(.system(size: 14, weight: .medium))
          if let caption = node.caption {
            Text(caption)
              .font(.system(size: 9, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
      )
      .help(node.title)
  }

  private func wattageLabel(_ watts: Double) -> some View {
    Text(String(format: "%.2f W", watts))
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .monospacedDigit()
      .shadow(color: .black.opacity(0.25), radius: 2)
      .menuCueNumericTransition(value: watts, importance: .primary)
  }

  // MARK: - Layout

  private struct FlowNode: Identifiable {
    let id: String
    let symbol: String
    let caption: String?
    let title: String
    var frame: CGRect
  }

  private struct FlowRibbon: Identifiable {
    let id: String
    let watts: Double
    let palette: RibbonPalette
    /// Center of the edge segment the ribbon attaches to, on each side.
    let start: CGPoint
    let startThickness: CGFloat
    let end: CGPoint
    let endThickness: CGFloat
  }

  private func plan(in size: CGSize) -> (nodes: [FlowNode], ribbons: [FlowRibbon]) {
    let height = size.height
    let rightX = size.width - Self.nodeWidth
    let startX = Self.nodeWidth
    let fullThickness = (height - 2 * Self.edgeInset) * Self.bandBudget

    switch state {
    case .charging(_, let batteryW, let systemW, let ratedW):
      let (batteryT, systemT) = bandThicknesses(batteryW, systemW, totalHeight: height)
      // Trunk: both bands stacked tight, centered on the plug. Far ends: pinned to
      // the top and bottom edges, so the streams visibly fork.
      let trunkTop = (height - batteryT - systemT - Self.trunkGap) / 2
      let batteryY = Self.edgeInset + batteryT / 2
      let systemY = height - Self.edgeInset - systemT / 2
      var battery = batteryNode(
        symbol: "battery.100percent.bolt", x: rightX, centerY: batteryY, height: height)
      var system = systemNode(x: rightX, centerY: systemY, height: height)
      pushApart(&battery, &system, in: height)
      return (
        [plugNode(ratedW, centerY: height / 2, height: height), battery, system],
        [
          FlowRibbon(
            id: "adapter-battery", watts: batteryW, palette: .adapter,
            start: CGPoint(x: startX, y: trunkTop + batteryT / 2),
            startThickness: batteryT,
            end: CGPoint(x: rightX, y: batteryY),
            endThickness: batteryT),
          FlowRibbon(
            id: "adapter-system", watts: systemW, palette: .adapter,
            start: CGPoint(x: startX, y: trunkTop + batteryT + Self.trunkGap + systemT / 2),
            startThickness: systemT,
            end: CGPoint(x: rightX, y: systemY),
            endThickness: systemT),
        ]
      )

    case .directSupply(let systemW, let ratedW):
      return (
        [plugNode(ratedW, centerY: height / 2, height: height),
         systemNode(x: rightX, centerY: height / 2, height: height)],
        [
          FlowRibbon(
            id: "adapter-system", watts: systemW, palette: .adapter,
            start: CGPoint(x: startX, y: height / 2), startThickness: fullThickness,
            end: CGPoint(x: rightX, y: height / 2), endThickness: fullThickness)
        ]
      )

    case .batteryAssist(let adapterW, let batteryW, _, let ratedW):
      // Mirror of charging: two sources pinned apart on the left merge into a
      // centered trunk at the system chip. The system total stays in the
      // accessibility sentence and the readout row below the diagram.
      let (adapterT, batteryT) = bandThicknesses(adapterW, batteryW, totalHeight: height)
      let trunkTop = (height - adapterT - batteryT - Self.trunkGap) / 2
      let adapterY = Self.edgeInset + adapterT / 2
      let batteryY = height - Self.edgeInset - batteryT / 2
      var plug = plugNode(ratedW, centerY: adapterY, height: height)
      var battery = batteryNode(symbol: "battery.75percent", x: 0, centerY: batteryY, height: height)
      pushApart(&plug, &battery, in: height)
      return (
        [plug, battery, systemNode(x: rightX, centerY: height / 2, height: height)],
        [
          FlowRibbon(
            id: "adapter-system", watts: adapterW, palette: .adapter,
            start: CGPoint(x: startX, y: adapterY),
            startThickness: adapterT,
            end: CGPoint(x: rightX, y: trunkTop + adapterT / 2),
            endThickness: adapterT),
          FlowRibbon(
            id: "battery-system", watts: batteryW, palette: .battery,
            start: CGPoint(x: startX, y: batteryY),
            startThickness: batteryT,
            end: CGPoint(x: rightX, y: trunkTop + adapterT + Self.trunkGap + batteryT / 2),
            endThickness: batteryT),
        ]
      )

    case .onBattery(let dischargeW):
      return (
        [batteryNode(symbol: "battery.75percent", x: 0, centerY: height / 2, height: height),
         systemNode(x: rightX, centerY: height / 2, height: height)],
        [
          FlowRibbon(
            id: "battery-system", watts: dischargeW, palette: .battery,
            start: CGPoint(x: startX, y: height / 2), startThickness: fullThickness,
            end: CGPoint(x: rightX, y: height / 2), endThickness: fullThickness)
        ]
      )
    }
  }

  /// A fixed-size chip vertically centered on its stream, kept inside the diagram.
  private func chipFrame(x: CGFloat, centerY: CGFloat, chipHeight: CGFloat, in height: CGFloat) -> CGRect {
    let y = min(max(centerY - chipHeight / 2, 0), height - chipHeight)
    return CGRect(x: x, y: y, width: Self.nodeWidth, height: chipHeight)
  }

  /// Fixed-size chips center on their own streams, so a thin top stream paired with a
  /// thick bottom one can drag a column's two chips into each other (worst case:
  /// assist from a weak adapter — the plug chip pinned at the top while the wide
  /// battery band pulls its chip up into it). Split the correction between whichever
  /// column edges still have room; chip heights sum well under the diagram height, so
  /// the seam always fits.
  private func pushApart(_ top: inout FlowNode, _ bottom: inout FlowNode, in height: CGFloat) {
    let overlap = top.frame.maxY + Self.chipGap - bottom.frame.minY
    guard overlap > 0 else { return }
    let drop = min(overlap - min(overlap / 2, top.frame.minY), height - bottom.frame.maxY)
    bottom.frame.origin.y += drop
    top.frame.origin.y -= min(overlap - drop, top.frame.minY)
  }

  private func plugNode(_ ratedW: Int?, centerY: CGFloat, height: CGFloat) -> FlowNode {
    FlowNode(
      id: "plug", symbol: "powerplug.fill", caption: ratedW.map { "\($0)W" },
      title: L10n.string("Adapter"),
      frame: chipFrame(x: 0, centerY: centerY, chipHeight: Self.plugChipHeight, in: height))
  }

  private func batteryNode(symbol: String, x: CGFloat, centerY: CGFloat, height: CGFloat) -> FlowNode {
    FlowNode(
      id: "battery", symbol: symbol, caption: nil, title: L10n.string("Battery"),
      frame: chipFrame(x: x, centerY: centerY, chipHeight: Self.batteryChipHeight, in: height))
  }

  private func systemNode(x: CGFloat, centerY: CGFloat, height: CGFloat) -> FlowNode {
    FlowNode(
      id: "system", symbol: "laptopcomputer", caption: nil, title: L10n.string("System"),
      frame: chipFrame(x: x, centerY: centerY, chipHeight: Self.systemChipHeight, in: height))
  }

  /// Splits the band budget between two streams purely by watts — a ribbon keeps one
  /// thickness end to end, so relative width IS the power reading. The floor only
  /// keeps the thin stream's label legible.
  private func bandThicknesses(
    _ firstWatts: Double, _ secondWatts: Double, totalHeight: CGFloat
  ) -> (CGFloat, CGFloat) {
    let usable = (totalHeight - 2 * Self.edgeInset - Self.trunkGap) * Self.bandBudget
    let sum = max(firstWatts + secondWatts, .leastNonzeroMagnitude)
    let proportional = usable * CGFloat(firstWatts / sum)
    let first = min(
      max(proportional, Self.minimumRibbonThickness), usable - Self.minimumRibbonThickness)
    return (first, usable - first)
  }

  // MARK: - Fills

  /// The AlDente look: dim at both ends with a bright hot spot left of center, like
  /// light flowing through smoked glass. The white stop desaturates the core so it
  /// reads as glow rather than solid pigment.
  private static func gradient(for palette: RibbonPalette) -> LinearGradient {
    let tint = palette.tint
    return LinearGradient(
      stops: [
        .init(color: tint.opacity(0.10), location: 0),
        .init(color: tint.opacity(0.80), location: 0.34),
        .init(color: palette.core.opacity(0.90), location: 0.44),
        .init(color: tint.opacity(0.30), location: 0.62),
        .init(color: tint.opacity(0.10), location: 1),
      ],
      startPoint: .leading, endPoint: .trailing)
  }

  /// A bright pulse sweeping source → sink as the flow-direction cue. It uses the
  /// palette's pale core (a tint-colored overlay was invisible on the already-lit
  /// band) and is narrow, so it reads as a traveling light rather than a general
  /// brightening. Strength follows sin²(πφ): faded out at both travel ends, so the
  /// phase wrap never pops.
  private static func shimmer(phase: Double, palette: RibbonPalette) -> LinearGradient {
    let strength = 0.55 * pow(sin(.pi * phase), 2)
    let center = min(max(phase, 0.001), 0.999)
    return LinearGradient(
      stops: [
        .init(color: .clear, location: max(0, center - 0.15)),
        .init(color: palette.core.opacity(strength), location: center),
        .init(color: .clear, location: min(1, center + 0.15)),
      ],
      startPoint: .leading, endPoint: .trailing)
  }

  // MARK: - Accessibility

  private var accessibilitySummary: String {
    func watts(_ value: Double) -> String { String(format: "%.1f W", value) }
    switch state {
    case .charging(_, let batteryW, let systemW, _):
      return L10n.format(
        "Adapter supplying %1$@ to the system and %2$@ to the battery",
        watts(systemW), watts(batteryW))
    case .directSupply(let systemW, _):
      return L10n.format("Adapter supplying %1$@ to the system", watts(systemW))
    case .batteryAssist(let adapterW, let batteryW, let systemW, _):
      return L10n.format(
        "System drawing %1$@, %2$@ from the adapter and %3$@ from the battery",
        watts(systemW), watts(adapterW), watts(batteryW))
    case .onBattery(let dischargeW):
      return L10n.format("Battery supplying %1$@ to the system", watts(dischargeW))
    }
  }
}

/// The classic Sankey S-curve: a closed path whose top and bottom edges are cubic
/// Béziers with control points at the horizontal midpoint, so a ribbon leaves its
/// source edge and meets its sink edge perpendicular to both.
private struct RibbonShape: Shape {
  var startX: CGFloat
  var endX: CGFloat
  var startY: CGFloat
  var startThickness: CGFloat
  var endY: CGFloat
  var endThickness: CGFloat

  /// The vertical geometry animates so ribbons reflow between samples; the x
  /// positions only change with the card width.
  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(AnimatablePair(startY, startThickness), AnimatablePair(endY, endThickness)) }
    set {
      startY = newValue.first.first
      startThickness = newValue.first.second
      endY = newValue.second.first
      endThickness = newValue.second.second
    }
  }

  func path(in _: CGRect) -> Path {
    let midX = (startX + endX) / 2
    let sourceTop = CGPoint(x: startX, y: startY - startThickness / 2)
    let sourceBottom = CGPoint(x: startX, y: startY + startThickness / 2)
    let sinkTop = CGPoint(x: endX, y: endY - endThickness / 2)
    let sinkBottom = CGPoint(x: endX, y: endY + endThickness / 2)

    var path = Path()
    path.move(to: sourceTop)
    path.addCurve(
      to: sinkTop,
      control1: CGPoint(x: midX, y: sourceTop.y),
      control2: CGPoint(x: midX, y: sinkTop.y))
    path.addLine(to: sinkBottom)
    path.addCurve(
      to: sourceBottom,
      control1: CGPoint(x: midX, y: sinkBottom.y),
      control2: CGPoint(x: midX, y: sourceBottom.y))
    path.closeSubpath()
    return path
  }
}
