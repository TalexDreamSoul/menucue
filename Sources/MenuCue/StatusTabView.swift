import Combine
import SwiftUI

/// Live system monitor tab. Sampling is tied to this view's lifetime so a closed
/// popover costs nothing.
struct StatusTabView: View {
  @Environment(\.menuCueMotion) private var motion
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject private var popoverPresentation = PopoverPresentationState.shared
  /// Owned here rather than by the popover: hover detail is only meaningful while
  /// this tab is on screen, and tearing it down on exit stops every extra probe.
  @StateObject private var detail = SystemDetailService()
  @StateObject private var samplingController = VisibilityGate()
  /// Measured, because the panel can only be kept inside the popover if its height
  /// is known — a naive above/below flip pushed tall panels off the top edge.
  @State private var detailPanelHeight: CGFloat = 0

  var body: some View {
    PopoverHapticScrollView {
      VStack(spacing: PopoverMetrics.cardSpacing) {
        SystemMetricsCards(metrics: metrics, detail: detail)

        // Pinned actions live here too so the common case needs no tab switch;
        // the Actions tab remains the full catalog.
        PopoverCard(title: "Quick Actions", systemImage: "bolt.fill", tint: .yellow) {
          Button("All") { router.openPopover(tab: .actions) }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        } content: {
          PinnedQuickActionGrid(model: model)
        }
      }
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
    .animation(motion.hoverAnimation, value: detail.target)
    .onAppear {
      samplingController.connect(
        to: popoverPresentation,
        onStart: {
          // Apply before retain() so the first timer uses the latest configured rate.
          metrics.applySamplingSettings(model.settings.metricsSampling)
          metrics.retain()
        },
        onStop: {
          metrics.release()
          detail.hover(nil)
        }
      )
      model.quickActionService.refreshAll()
    }
    .onDisappear {
      samplingController.disconnect()
    }
    .onChange(of: model.settings.metricsSampling) { sampling in
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
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var detail: SystemDetailService

  private static let userColor = Color.accentColor
  private static let systemColor = Color.orange
  private static let idleColor = Color.secondary

  var body: some View {
    VStack(spacing: PopoverMetrics.cardSpacing) {
      cpuCard
        .metricDetailSource(.cpu, service: detail, open: link(.cpu))
      Grid(horizontalSpacing: PopoverMetrics.cardSpacing, verticalSpacing: PopoverMetrics.cardSpacing)
      {
        GridRow {
          memoryCard
            .metricDetailSource(.memory, service: detail, open: link(.memory))
          diskCard
            .metricDetailSource(.disk, service: detail, open: link(.disk))
        }
        // Fanless Macs (MacBook Air, Mac mini M-series) report no tachometers at all.
        if metrics.snapshot.fans.isEmpty {
          GridRow {
            networkCard
              .metricDetailSource(.network, service: detail, open: link(.network))
              .gridCellColumns(2)
          }
        } else {
          GridRow {
            fanCard
            .metricDetailSource(.fan, service: detail, open: link(.fan))
            networkCard
            .metricDetailSource(.network, service: detail, open: link(.network))
          }
        }
      }
    }
  }

  /// Opens the Dashboard window on the tab that expands this card.
  private func link(_ target: MetricDetailTarget) -> (() -> Void)? {
    { router.openDashboard(section: DashboardSection(target: target)) }
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
          .menuCueNumericTransition(value: temperature)
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
          .menuCueNumericTransition(value: snapshot.cpu.busy, importance: .primary)
      }

      CPUUsageChart(
        samples: metrics.cpuHistory,
        capacity: metrics.historyCapacity,
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
      Text(L10n.string("Physical Memory"))
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
    }
  }

  // MARK: - Fans

  private var fanCard: some View {
    let fans = metrics.snapshot.fans

    return PopoverCard(title: "Fan", systemImage: "fanblades", tint: .cyan, fillsHeight: true) {
      Text(
        fans.count == 1
          ? L10n.string("1 fan")
          : L10n.format("%d fans", fans.count)
      )
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    } content: {
      ForEach(fans) { fan in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 4) {
            Text(L10n.format("Fan %d", fan.index + 1))
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(L10n.format("%d RPM", Int(fan.currentRPM)))
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .menuCueNumericTransition(value: fan.currentRPM)
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
