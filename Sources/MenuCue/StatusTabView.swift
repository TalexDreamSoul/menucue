import SwiftUI

/// Live system monitor tab. Sampling is tied to this view's lifetime so a closed
/// popover costs nothing.
struct StatusTabView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var metrics: SystemMetricsService
  let openAllActions: () -> Void
  /// Owned here rather than by the popover: hover detail is only meaningful while
  /// this tab is on screen, and tearing it down on exit stops every extra probe.
  @StateObject private var detail = SystemDetailService()
  /// Measured, because the panel can only be kept inside the popover if its height
  /// is known — a naive above/below flip pushed tall panels off the top edge.
  @State private var detailPanelHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      VStack(spacing: PopoverMetrics.cardSpacing) {
        SystemMetricsCards(metrics: metrics, detail: detail)

        // Pinned actions live here too so the common case needs no tab switch;
        // the Actions tab remains the full catalog.
        PopoverCard(title: "Quick Actions", systemImage: "bolt.fill", tint: .yellow) {
          Button("All", action: openAllActions)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        } content: {
          PinnedQuickActionGrid(model: model)
        }
      }
      .padding(.horizontal, PopoverMetrics.contentPadding)
      .padding(.vertical, 2)
    }
    .overlayPreferenceValue(MetricDetailAnchorKey.self) { anchors in
      GeometryReader { proxy in
        if let target = detail.target, let anchor = anchors[target] {
          detailPanel(for: target, cardFrame: proxy[anchor], container: proxy.size)
        }
      }
      // The panel must never take hover away from the card that opened it.
      .allowsHitTesting(false)
    }
    .animation(PopoverMotion.hover, value: detail.target)
    .onAppear {
      // Applied before retain() so the first timer is already scheduled at the
      // battery-appropriate rate rather than being rebuilt one tick later.
      metrics.applySamplingSettings(model.settings.metricsSampling)
      metrics.retain()
      model.quickActionService.refreshAll()
    }
    .onDisappear {
      metrics.release()
      detail.hover(nil)
    }
    .onChange(of: model.settings.metricsSampling) { _, sampling in
      metrics.applySamplingSettings(sampling)
    }
  }
}

extension StatusTabView {
  static let detailPanelWidth: CGFloat = 244
  static let detailPanelGap: CGFloat = 6

  /// Prefers below the card, flips above when that overflows, and finally clamps
  /// into the container so the panel is never cut off by the popover edge.
  @ViewBuilder
  fileprivate func detailPanel(
    for target: MetricDetailTarget,
    cardFrame: CGRect,
    container: CGSize
  ) -> some View {
    let origin = Self.panelOrigin(
      cardFrame: cardFrame, container: container, height: detailPanelHeight)
    let height = detailPanelHeight

    ZStack(alignment: .topLeading) {
      Color.clear
      MetricDetailPanel(target: target, detail: detail, snapshot: metrics.snapshot)
        .frame(width: Self.detailPanelWidth)
        .background(
          GeometryReader { panel in
            Color.clear.preference(
              key: MetricDetailHeightKey.self, value: panel.size.height)
          }
        )
        .offset(x: origin.x, y: origin.y)
        // The first frame has no measurement yet; showing it would flash at y = 0.
        .opacity(height > 0 ? 1 : 0)
    }
    .onPreferenceChange(MetricDetailHeightKey.self) { measured in
      detailPanelHeight = measured
    }
  }

  /// Prefers below, flips above when that overflows, and finally clamps into the
  /// container so a tall panel is never cut off by the popover edge.
  static func panelOrigin(cardFrame: CGRect, container: CGSize, height: CGFloat) -> CGPoint {
    let inset = PopoverMetrics.contentPadding
    let width = detailPanelWidth
    let x = clamp(
      cardFrame.midX - width / 2, lower: inset, upper: container.width - width - inset)

    let below = cardFrame.maxY + detailPanelGap
    let above = cardFrame.minY - detailPanelGap - height
    let lowestTop = container.height - height - inset

    if below <= lowestTop {
      return CGPoint(x: x, y: below)
    }
    if above >= inset {
      return CGPoint(x: x, y: above)
    }
    // Taller than the room on either side: clamp rather than run off an edge.
    return CGPoint(x: x, y: clamp(above, lower: inset, upper: max(inset, lowestTop)))
  }

  static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    guard upper > lower else { return lower }
    return min(upper, max(lower, value))
  }
}

/// The card stack itself, kept separate from the scroll container so it can be
/// laid out and snapshot-rendered on its own.
struct SystemMetricsCards: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var detail: SystemDetailService

  private static let userColor = Color.accentColor
  private static let systemColor = Color.orange
  private static let idleColor = Color.secondary

  var body: some View {
    VStack(spacing: PopoverMetrics.cardSpacing) {
      cpuCard
        .metricDetailSource(.cpu, service: detail)
      Grid(horizontalSpacing: PopoverMetrics.cardSpacing, verticalSpacing: PopoverMetrics.cardSpacing)
      {
        GridRow {
          memoryCard
            .metricDetailSource(.memory, service: detail)
          diskCard
            .metricDetailSource(.disk, service: detail)
        }
        // Fanless Macs (MacBook Air, Mac mini M-series) report no tachometers at all.
        if metrics.snapshot.fans.isEmpty {
          GridRow {
            networkCard
              .metricDetailSource(.network, service: detail)
              .gridCellColumns(2)
          }
        } else {
          GridRow {
            fanCard
            .metricDetailSource(.fan, service: detail)
            networkCard
            .metricDetailSource(.network, service: detail)
          }
        }
      }
    }
  }

  // MARK: - CPU

  private var cpuCard: some View {
    let snapshot = metrics.snapshot

    return PopoverCard(title: "CPU", systemImage: "cpu", tint: Self.userColor) {
      if let temperature = snapshot.cpuTemperature {
        Text(SystemMetricsFormatter.temperature(temperature))
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(temperatureColor(temperature))
          .contentTransition(.numericText())
          .animation(PopoverMotion.value, value: temperature)
      }
    } content: {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(metrics.hardware.chipName)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          if !metrics.hardware.coreSummary.isEmpty {
            Text(metrics.hardware.coreSummary)
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(.tertiary)
          }
        }
        Spacer(minLength: 8)
        Text(SystemMetricsFormatter.percent(snapshot.cpu.busy))
          .font(.system(size: 20, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(PopoverMotion.value, value: snapshot.cpu.busy)
      }

      CPUUsageChart(
        samples: metrics.cpuHistory,
        capacity: SystemMetricsService.historyCapacity,
        userColor: Self.userColor,
        systemColor: Self.systemColor
      )
      .frame(height: 62)

      HStack(spacing: 0) {
        LegendItem(
          color: Self.userColor,
          label: "User",
          value: SystemMetricsFormatter.percent(snapshot.cpu.userBand))
        Spacer(minLength: 6)
        LegendItem(
          color: Self.systemColor,
          label: "System",
          value: SystemMetricsFormatter.percent(snapshot.cpu.systemBand))
        Spacer(minLength: 6)
        LegendItem(
          color: Self.idleColor.opacity(0.4),
          label: "Idle",
          value: SystemMetricsFormatter.percent(snapshot.cpu.idle))
      }
    }
  }

  private func temperatureColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<65: return .green
    case ..<85: return .orange
    default: return .red
    }
  }

  // MARK: - Memory

  private var memoryCard: some View {
    let memory = metrics.snapshot.memory

    return PopoverCard(title: "Memory", systemImage: "memorychip", tint: .purple, fillsHeight: true) {
      Text(SystemMetricsFormatter.percent(memory.fraction))
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    } content: {
      // Mirrors the Disk card's volume name so both bars land on the same line
      // when the two cards share a row.
      Text("Physical Memory")
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      MetricBar(fraction: memory.fraction, tint: .purple)
      HStack(spacing: 4) {
        MetricReadout(label: "Used", value: SystemMetricsFormatter.capacity(memory.used))
        MetricReadout(
          label: "Total",
          value: SystemMetricsFormatter.capacity(memory.total),
          alignment: .trailing)
      }
      MetricReadout(
        label: "Cached",
        value: SystemMetricsFormatter.capacity(memory.cached),
        valueColor: .secondary)
    }
  }

  // MARK: - Disk

  private var diskCard: some View {
    let disk = metrics.snapshot.disk

    return PopoverCard(title: "Disk", systemImage: "internaldrive", tint: .teal, fillsHeight: true) {
      Text(SystemMetricsFormatter.percent(disk.fraction))
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    } content: {
      Text(disk.volumeName)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      MetricBar(fraction: disk.fraction, tint: .teal)
      HStack(spacing: 4) {
        MetricReadout(label: "Used", value: SystemMetricsFormatter.capacity(disk.used))
        MetricReadout(
          label: "Total",
          value: SystemMetricsFormatter.capacity(disk.total),
          alignment: .trailing)
      }
      HStack(spacing: 4) {
        MetricReadout(
          label: "Read",
          value: SystemMetricsFormatter.rate(disk.readBytesPerSecond),
          valueColor: .secondary)
        MetricReadout(
          label: "Write",
          value: SystemMetricsFormatter.rate(disk.writeBytesPerSecond),
          valueColor: .secondary,
          alignment: .trailing)
      }
    }
  }

  // MARK: - Fans

  private var fanCard: some View {
    let fans = metrics.snapshot.fans

    return PopoverCard(title: "Fan", systemImage: "fanblades", tint: .cyan, fillsHeight: true) {
      Text(fans.count == 1 ? "1 fan" : "\(fans.count) fans")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    } content: {
      ForEach(fans) { fan in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 4) {
            Text("Fan \(fan.index + 1)")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(Int(fan.currentRPM)) RPM")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .contentTransition(.numericText())
              .animation(PopoverMotion.value, value: fan.currentRPM)
          }
          if fan.maxRPM > fan.minRPM {
            MetricBar(fraction: fan.loadFraction, tint: .cyan, height: 4)
          }
        }
      }
    }
  }

  // MARK: - Network

  private var networkCard: some View {
    let network = metrics.snapshot.network

    return PopoverCard(title: "Network", systemImage: "globe", tint: .blue, fillsHeight: true) {
      if let interface = network.interfaceName {
        Text(interface)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.tertiary)
      }
    } content: {
      HStack(spacing: 4) {
        MetricReadout(
          label: "Download",
          value: SystemMetricsFormatter.rate(network.downloadBytesPerSecond))
        MetricReadout(
          label: "Upload",
          value: SystemMetricsFormatter.rate(network.uploadBytesPerSecond),
          alignment: .trailing)
      }
      if let address = network.ipv4Address {
        HStack(spacing: 4) {
          Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
          Text(address)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.blue)
            .textSelection(.enabled)
        }
      } else {
        CardPlaceholder(message: "No IPv4 address")
      }
    }
  }
}

/// Stacked area chart of recent CPU load: user time on the bottom band, system time above it.
private struct CPUUsageChart: View {
  let samples: [CPULoadSample]
  let capacity: Int
  let userColor: Color
  let systemColor: Color

  var body: some View {
    Canvas { context, size in
      let baseline = Path(
        roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8, style: .continuous)
      context.fill(baseline, with: .color(.primary.opacity(0.05)))

      guard !samples.isEmpty else { return }
      context.clip(to: baseline)

      // Drawn back to front: the combined band first, then user on top of it.
      let combined = areaPath(in: size) { $0.userBand + $0.systemBand }
      context.fill(combined, with: .color(systemColor.opacity(0.55)))

      let user = areaPath(in: size) { $0.userBand }
      context.fill(user, with: .color(userColor.opacity(0.55)))

      context.stroke(
        linePath(in: size) { $0.userBand + $0.systemBand },
        with: .color(systemColor),
        lineWidth: 1.2)
      context.stroke(
        linePath(in: size) { $0.userBand },
        with: .color(userColor),
        lineWidth: 1.2)
    }
    .accessibilityHidden(true)
  }

  private func points(in size: CGSize, value: (CPULoadSample) -> Double) -> [CGPoint] {
    func y(_ sample: CPULoadSample) -> CGFloat {
      size.height * (1 - min(1, max(0, value(sample))))
    }

    // A lone sample is drawn flat across the width so the first frame after opening
    // shows a real level instead of an empty box.
    guard samples.count > 1 else {
      return samples.first.map { [CGPoint(x: 0, y: y($0)), CGPoint(x: size.width, y: y($0))] } ?? []
    }

    // Spread whatever history exists across the full width. Once the buffer is
    // saturated this is a fixed window, so the series scrolls instead of rescaling —
    // and a freshly opened popover never shows a mostly empty chart.
    let slot = size.width / CGFloat(min(samples.count, capacity) - 1)
    return samples.enumerated().map { index, sample in
      CGPoint(x: CGFloat(index) * slot, y: y(sample))
    }
  }

  private func linePath(in size: CGSize, value: (CPULoadSample) -> Double) -> Path {
    var path = Path()
    let points = points(in: size, value: value)
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
      path.addLine(to: point)
    }
    return path
  }

  private func areaPath(in size: CGSize, value: (CPULoadSample) -> Double) -> Path {
    var path = linePath(in: size, value: value)
    let points = points(in: size, value: value)
    guard let first = points.first, let last = points.last else { return path }
    path.addLine(to: CGPoint(x: last.x, y: size.height))
    path.addLine(to: CGPoint(x: first.x, y: size.height))
    path.closeSubpath()
    return path
  }
}
