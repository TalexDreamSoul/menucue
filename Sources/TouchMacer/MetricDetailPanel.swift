import SwiftUI

/// Publishes each metric card's frame so the hover panel can anchor to it without
/// the cards knowing anything about the panel.
struct MetricDetailAnchorKey: PreferenceKey {
  static let defaultValue: [MetricDetailTarget: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [MetricDetailTarget: Anchor<CGRect>],
    nextValue: () -> [MetricDetailTarget: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

extension View {
  /// Marks a card as the hover source for `target`.
  func metricDetailSource(_ target: MetricDetailTarget, service: SystemDetailService) -> some View {
    anchorPreference(key: MetricDetailAnchorKey.self, value: .bounds) { [target: $0] }
      .onHover { hovering in
        if hovering {
          service.hover(target)
        } else if service.target == target {
          // Only the card that owns the panel may dismiss it, otherwise the exit
          // event of the card you just left closes the one you just entered.
          service.hover(nil)
        }
      }
      .focusable()
      .onKeyPress(.return) {
        service.toggle(target)
        return .handled
      }
      .onKeyPress(.space) {
        service.toggle(target)
        return .handled
      }
      .accessibilityLabel(target.title)
      .accessibilityHint(L10n.string("Show metric details"))
      .accessibilityAction { service.toggle(target) }
  }
}

/// Floating detail for the hovered metric card. Rendered in the popover's own
/// coordinate space rather than as a nested popover, which a transient NSPopover
/// does not host reliably.
struct MetricDetailPanel: View {
  let target: MetricDetailTarget
  @ObservedObject var detail: SystemDetailService
  let snapshot: SystemMetricsSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(target.title)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .kerning(0.4)

      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
  }

  @ViewBuilder
  private var content: some View {
    switch target {
    case .cpu: cpuDetail
    case .memory: memoryDetail
    case .disk: diskDetail
    case .network: networkDetail
    case .fan: fanDetail
    }
  }

  // MARK: - CPU & GPU

  @ViewBuilder
  private var cpuDetail: some View {
    DetailRow(label: "CPU busy", value: SystemMetricsFormatter.percent(snapshot.cpu.busy))
    DetailRow(label: "User", value: SystemMetricsFormatter.percent(snapshot.cpu.userBand))
    DetailRow(label: "System", value: SystemMetricsFormatter.percent(snapshot.cpu.systemBand))

    if !detail.gpu.isEmpty {
      Divider().opacity(0.4)
      if let device = detail.gpu.deviceUtilization {
        DetailRow(label: "GPU", value: SystemMetricsFormatter.percent(device))
        MetricBar(fraction: device, tint: .green, height: 4)
      }
      if let renderer = detail.gpu.rendererUtilization {
        DetailRow(label: "Renderer", value: SystemMetricsFormatter.percent(renderer))
      }
      if let memory = detail.gpu.inUseMemory {
        DetailRow(label: "GPU memory", value: SystemMetricsFormatter.capacity(memory))
      }
    }

    if !detail.thermals.isEmpty {
      Divider().opacity(0.4)
      ForEach(detail.thermals) { reading in
        DetailRow(
          label: L10n.string(reading.label),
          value: SystemMetricsFormatter.temperature(reading.celsius))
      }
    } else if detail.isLoading {
      DetailPlaceholder(message: "Reading sensors…")
    }
  }

  // MARK: - Memory

  @ViewBuilder
  private var memoryDetail: some View {
    let memory = snapshot.memory
    DetailRow(label: "App memory", value: SystemMetricsFormatter.capacity(memory.appMemory))
    DetailRow(label: "Wired", value: SystemMetricsFormatter.capacity(memory.wired))
    DetailRow(label: "Compressed", value: SystemMetricsFormatter.capacity(memory.compressed))
    DetailRow(label: "Cached", value: SystemMetricsFormatter.capacity(memory.cached))

    Divider().opacity(0.4)

    if detail.topProcesses.isEmpty {
      DetailPlaceholder(
        message: detail.isLoading ? "Scanning processes…" : "No readable processes.")
    } else {
      let peak = detail.topProcesses.first?.residentBytes ?? 1
      ForEach(detail.topProcesses) { process in
        VStack(alignment: .leading, spacing: 2) {
          DetailRow(
            label: process.name,
            value: SystemMetricsFormatter.capacity(process.residentBytes))
          MetricBar(
            fraction: peak == 0 ? 0 : Double(process.residentBytes) / Double(peak),
            tint: .purple,
            height: 3)
        }
      }
    }
  }

  // MARK: - Disk

  @ViewBuilder
  private var diskDetail: some View {
    let disk = snapshot.disk
    let free = disk.total > disk.used ? disk.total - disk.used : 0
    DetailRow(
      label: "Free", value: SystemMetricsFormatter.capacity(free), emphasized: true)
    DetailRow(label: "Used", value: SystemMetricsFormatter.capacity(disk.used))
    DetailRow(label: "Capacity", value: SystemMetricsFormatter.capacity(disk.total))
    Divider().opacity(0.4)
    DetailRow(label: "Read", value: SystemMetricsFormatter.rate(disk.readBytesPerSecond))
    DetailRow(label: "Write", value: SystemMetricsFormatter.rate(disk.writeBytesPerSecond))
  }

  // MARK: - Network

  @ViewBuilder
  private var networkDetail: some View {
    let network = snapshot.network
    DetailRow(label: "Interface", value: network.interfaceName ?? "—")
    DetailRow(label: "IPv4", value: network.ipv4Address ?? "—")
    Divider().opacity(0.4)
    DetailRow(
      label: "Download", value: SystemMetricsFormatter.rate(network.downloadBytesPerSecond))
    DetailRow(label: "Upload", value: SystemMetricsFormatter.rate(network.uploadBytesPerSecond))
  }

  // MARK: - Fans

  @ViewBuilder
  private var fanDetail: some View {
    if snapshot.fans.isEmpty {
      DetailPlaceholder(message: "This Mac reports no fans.")
    } else {
      ForEach(snapshot.fans) { fan in
        VStack(alignment: .leading, spacing: 2) {
          DetailRow(
            label: L10n.format("Fan %d", fan.index + 1),
            value: L10n.format("%d RPM", Int(fan.currentRPM))
          )
          if fan.maxRPM > fan.minRPM {
            MetricBar(fraction: fan.loadFraction, tint: .cyan, height: 3)
            DetailRow(
              label: "Range",
              value: L10n.format("%d–%d RPM", Int(fan.minRPM), Int(fan.maxRPM)),
              subdued: true)
          }
        }
      }
    }
  }
}

private struct DetailRow: View {
  let label: String
  let value: String
  var emphasized = false
  var subdued = false

  var body: some View {
    HStack(spacing: 8) {
      Text(L10n.string(label))
        .font(.system(size: subdued ? 9 : 10))
        .foregroundStyle(subdued ? .tertiary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 6)
      Text(value)
        // Size carries the hierarchy as well as color, so a subdued row can never
        // out-shout its own headline whatever the material resolves the tints to.
        .font(
          .system(
            size: emphasized ? 13 : (subdued ? 9 : 10.5),
            weight: subdued ? .medium : .semibold,
            design: .rounded)
        )
        .monospacedDigit()
        .foregroundStyle(subdued ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .lineLimit(1)
    }
  }
}

private struct DetailPlaceholder: View {
  let message: String

  var body: some View {
    Text(L10n.string(message))
      .font(.system(size: 10))
      .foregroundStyle(.tertiary)
  }
}

/// Reports the rendered panel height back to the placement code.
struct MetricDetailHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
