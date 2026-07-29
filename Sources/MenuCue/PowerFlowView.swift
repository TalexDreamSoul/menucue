import SwiftUI

/// AlDente-style power-path diagram for the Battery Flow card: ribbons between an
/// adapter node, a battery node, and the system node, with thickness tracking watts
/// and a warm gradient glowing along the flow direction. Rendered only when
/// `PowerFlowState.make` classified live telemetry; the card keeps its flat bar
/// otherwise.
struct PowerFlowView: View {
  let state: PowerFlowState

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var popoverPresentation = PopoverPresentationState.shared

  private static let diagramHeight: CGFloat = 96
  private static let nodeWidth: CGFloat = 44
  private static let nodeGap: CGFloat = 6
  private static let minimumNodeHeight: CGFloat = 28
  private static let minimumRibbonThickness: CGFloat = 12
  /// Ribbons attach inside the node edge so the chip's rounded corners stay visible.
  private static let edgeInset: CGFloat = 5
  private static let splitRibbonGap: CGFloat = 4
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
  private static let shimmerPeriod: TimeInterval = 6

  var body: some View {
    Group {
      if reduceMotion {
        diagram(shimmerPhase: nil)
      } else {
        // Paused while the popover is hidden: NSPopover keeps its content view
        // controller alive after close, so "no 20 fps tick in the background" is a
        // property of this schedule rather than of AppKit teardown — the same
        // visibility gate PowerTabView uses for its sampling.
        TimelineView(
          .animation(minimumInterval: 1 / 20, paused: !popoverPresentation.isVisible)
        ) { context in
          diagram(
            shimmerPhase: context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: Self.shimmerPeriod) / Self.shimmerPeriod)
        }
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
            shape.fill(Self.shimmer(phase: shimmerPhase, tint: ribbon.palette.tint))
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
      .animation(PopoverMotion.value, value: state)
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
          // A minimum-height node has no room for the rating under the glyph.
          if let caption = node.caption, node.frame.height >= 40 {
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
      .contentTransition(.numericText())
      .animation(PopoverMotion.value, value: watts)
  }

  // MARK: - Layout

  private struct FlowNode: Identifiable {
    let id: String
    let symbol: String
    let caption: String?
    let title: String
    let frame: CGRect
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
    let fullThickness = height - 2 * Self.edgeInset

    switch state {
    case .charging(_, let batteryW, let systemW, let ratedW):
      let (batteryH, systemH) = nodeHeights(batteryW, systemW, totalHeight: height)
      let (batteryT, systemT) = edgeThicknesses(batteryW, systemW, nodeHeight: height)
      let battery = FlowNode(
        id: "battery", symbol: "battery.100percent.bolt", caption: nil,
        title: L10n.string("Battery"),
        frame: CGRect(x: rightX, y: 0, width: Self.nodeWidth, height: batteryH))
      let system = FlowNode(
        id: "system", symbol: "laptopcomputer", caption: nil,
        title: L10n.string("System"),
        frame: CGRect(x: rightX, y: height - systemH, width: Self.nodeWidth, height: systemH))
      return (
        [plugNode(ratedW, frame: CGRect(x: 0, y: 0, width: Self.nodeWidth, height: height)),
         battery, system],
        [
          FlowRibbon(
            id: "adapter-battery", watts: batteryW, palette: .adapter,
            start: CGPoint(x: startX, y: Self.edgeInset + batteryT / 2),
            startThickness: batteryT,
            end: CGPoint(x: rightX, y: battery.frame.midY),
            endThickness: batteryH - 2 * Self.edgeInset),
          FlowRibbon(
            id: "adapter-system", watts: systemW, palette: .adapter,
            start: CGPoint(x: startX, y: height - Self.edgeInset - systemT / 2),
            startThickness: systemT,
            end: CGPoint(x: rightX, y: system.frame.midY),
            endThickness: systemH - 2 * Self.edgeInset),
        ]
      )

    case .directSupply(let systemW, let ratedW):
      return (
        [plugNode(ratedW, frame: CGRect(x: 0, y: 0, width: Self.nodeWidth, height: height)),
         systemNode(frame: CGRect(x: rightX, y: 0, width: Self.nodeWidth, height: height))],
        [
          FlowRibbon(
            id: "adapter-system", watts: systemW, palette: .adapter,
            start: CGPoint(x: startX, y: height / 2), startThickness: fullThickness,
            end: CGPoint(x: rightX, y: height / 2), endThickness: fullThickness)
        ]
      )

    case .batteryAssist(let adapterW, let batteryW, _, let ratedW):
      // The two merge ribbons already carry the split; the system total stays in the
      // accessibility sentence and the readout row below the diagram.
      let (adapterH, batteryH) = nodeHeights(adapterW, batteryW, totalHeight: height)
      let (adapterT, batteryT) = edgeThicknesses(adapterW, batteryW, nodeHeight: height)
      let plug = plugNode(
        ratedW, frame: CGRect(x: 0, y: 0, width: Self.nodeWidth, height: adapterH))
      let battery = FlowNode(
        id: "battery", symbol: "battery.75percent", caption: nil,
        title: L10n.string("Battery"),
        frame: CGRect(x: 0, y: height - batteryH, width: Self.nodeWidth, height: batteryH))
      return (
        [plug, battery,
         systemNode(frame: CGRect(x: rightX, y: 0, width: Self.nodeWidth, height: height))],
        [
          FlowRibbon(
            id: "adapter-system", watts: adapterW, palette: .adapter,
            start: CGPoint(x: startX, y: plug.frame.midY),
            startThickness: adapterH - 2 * Self.edgeInset,
            end: CGPoint(x: rightX, y: Self.edgeInset + adapterT / 2),
            endThickness: adapterT),
          FlowRibbon(
            id: "battery-system", watts: batteryW, palette: .battery,
            start: CGPoint(x: startX, y: battery.frame.midY),
            startThickness: batteryH - 2 * Self.edgeInset,
            end: CGPoint(x: rightX, y: height - Self.edgeInset - batteryT / 2),
            endThickness: batteryT),
        ]
      )

    case .onBattery(let dischargeW):
      return (
        [FlowNode(
          id: "battery", symbol: "battery.75percent", caption: nil,
          title: L10n.string("Battery"),
          frame: CGRect(x: 0, y: 0, width: Self.nodeWidth, height: height)),
         systemNode(frame: CGRect(x: rightX, y: 0, width: Self.nodeWidth, height: height))],
        [
          FlowRibbon(
            id: "battery-system", watts: dischargeW, palette: .battery,
            start: CGPoint(x: startX, y: height / 2), startThickness: fullThickness,
            end: CGPoint(x: rightX, y: height / 2), endThickness: fullThickness)
        ]
      )
    }
  }

  private func plugNode(_ ratedW: Int?, frame: CGRect) -> FlowNode {
    FlowNode(
      id: "plug", symbol: "powerplug.fill", caption: ratedW.map { "\($0)W" },
      title: L10n.string("Adapter"), frame: frame)
  }

  private func systemNode(frame: CGRect) -> FlowNode {
    FlowNode(
      id: "system", symbol: "laptopcomputer", caption: nil,
      title: L10n.string("System"), frame: frame)
  }

  /// Splits a column between two nodes proportionally to watts, with a floor that
  /// keeps the smaller chip's glyph readable — the AlDente reading where node height
  /// tracks ribbon thickness.
  private func nodeHeights(
    _ firstWatts: Double, _ secondWatts: Double, totalHeight: CGFloat
  ) -> (CGFloat, CGFloat) {
    let usable = totalHeight - Self.nodeGap
    let sum = max(firstWatts + secondWatts, .leastNonzeroMagnitude)
    let proportional = usable * CGFloat(firstWatts / sum)
    let first = min(
      max(proportional, Self.minimumNodeHeight), usable - Self.minimumNodeHeight)
    return (first, usable - first)
  }

  /// Splits one full-height node edge between its two ribbons, again proportionally
  /// to watts with a floor so the thin ribbon's label still fits.
  private func edgeThicknesses(
    _ firstWatts: Double, _ secondWatts: Double, nodeHeight: CGFloat
  ) -> (CGFloat, CGFloat) {
    let usable = nodeHeight - 2 * Self.edgeInset - Self.splitRibbonGap
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

  /// A soft highlight drifting toward the sinks as the flow-direction cue. Its
  /// strength follows sin²(πφ), so it fades out before the phase wraps instead of
  /// popping back to the left edge.
  private static func shimmer(phase: Double, tint: Color) -> LinearGradient {
    let strength = 0.30 * pow(sin(.pi * phase), 2)
    return LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: tint.opacity(strength), location: min(max(phase, 0.001), 0.999)),
        .init(color: .clear, location: 1),
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
