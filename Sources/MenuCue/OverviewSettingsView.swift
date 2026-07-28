import Combine
import SwiftUI

/// Settings landing pane: what this Mac is, what MenuCue is currently doing, and
/// anything that needs attention — every check row jumps to the pane that fixes it.
///
/// Deliberately does not start sampling. It renders the snapshot the popover last
/// captured, labelled with its age, so opening Settings costs no battery.
struct OverviewSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var updateService: UpdateService
  @ObservedObject private var powerHelper: PowerHelperManager
  @ObservedObject private var syncService: PreferenceSyncService
  @ObservedObject private var quickActionService: QuickActionService
  let selectPane: (SettingsPane) -> Void

  private let hardware = SystemMetricsProbe.hardwareInfo()
  private let bootDate = SystemMetricsProbe.bootDate()
  @State private var cache: SystemMetricsService.Cache?
  @State private var powerSource: PowerSourceState = .unknown

  init(
    model: AppModel,
    updateService: UpdateService,
    selectPane: @escaping (SettingsPane) -> Void
  ) {
    self.model = model
    self.updateService = updateService
    self.selectPane = selectPane
    self.powerHelper = model.quickActionService.powerHelperManager
    self.syncService = model.preferenceSyncService
    self.quickActionService = model.quickActionService
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      machineGroup
      metricsGroup
      samplingGroup
      activeActionsGroup
      checksGroup
    }
    .onAppear {
      // Any age is fine here because the reading is labelled with it; the popover's
      // stricter freshness window exists to keep live rates honest, not this pane.
      cache = SystemMetricsService.loadCache(from: .standard, maxAge: .infinity)
      powerSource = PowerSourceReader.current()
      quickActionService.refreshAll()
    }
    .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
      powerSource = PowerSourceReader.current()
    }
  }

  // MARK: - Machine

  private var machineGroup: some View {
    SettingsGroup(spacing: 6) {
      Text(hardware.chipName)
        .font(.title3.weight(.semibold))
      Text(machineDetail)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var machineDetail: String {
    var parts: [String] = []
    if !hardware.coreSummary.isEmpty { parts.append(hardware.coreSummary) }
    if let memory = cache?.snapshot.memory, memory.total > 0 {
      parts.append(SystemMetricsFormatter.capacity(memory.total))
    }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    parts.append("macOS \(version.majorVersion).\(version.minorVersion)")
    if let bootDate {
      parts.append(
        L10n.format("up %@", SystemMetricsFormatter.uptime(Date().timeIntervalSince(bootDate))))
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Metrics

  private var metricsGroup: some View {
    SettingsGroup(spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(L10n.string("Last reading"))
          .font(.headline)
        Spacer()
        Text(readingAgeText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let snapshot = cache?.snapshot {
        HStack(spacing: 10) {
          OverviewMetricTile(
            title: "CPU", value: SystemMetricsFormatter.percent(snapshot.cpu.busy),
            fraction: snapshot.cpu.busy, tint: .blue)
          OverviewMetricTile(
            title: "Memory", value: SystemMetricsFormatter.percent(snapshot.memory.fraction),
            fraction: snapshot.memory.fraction, tint: .purple)
          OverviewMetricTile(
            title: "Disk", value: SystemMetricsFormatter.percent(snapshot.disk.fraction),
            fraction: snapshot.disk.fraction, tint: .teal)
        }
      } else {
        Text(L10n.string("No reading cached yet. Open the menu-bar popover to sample this Mac."))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var readingAgeText: String {
    guard let savedAt = cache?.savedAt else { return L10n.string("Never") }
    let elapsed = Date().timeIntervalSince(savedAt)
    guard elapsed >= 0 else { return L10n.string("Just now") }
    if elapsed < 60 { return L10n.string("Just now") }
    return L10n.format("%@ ago", SystemMetricsFormatter.uptime(elapsed))
  }

  // MARK: - Sampling

  private var sampling: MetricsSamplingSettings { model.settings.metricsSampling }

  private var samplingGroup: some View {
    SettingsGroup(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.string("Sampling"))
          .font(.headline)
        Text(
          L10n.string(
            "Adaptive sampling runs fastest on wall power and eases off as the battery drains, so a long unplugged session costs less."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Toggle(
        "Adapt sampling rate to battery level",
        isOn: Binding(
          get: { sampling.isAdaptive },
          set: { value in model.updateMetricsSampling { $0.isAdaptive = value } }
        )
      )

      HStack {
        Label(powerSourceText, systemImage: powerSourceIcon)
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Text(
          L10n.format("Now sampling every %@", AdaptiveSamplingPolicy.describe(effectiveInterval))
        )
          .font(.callout.weight(.medium))
          .monospacedDigit()
      }

      intervalStepper(
        title: "On wall power / full battery",
        value: sampling.fastestIntervalSeconds,
        onChange: { delta in
          model.updateMetricsSampling { settings in
            settings.fastestIntervalSeconds += delta
          }
        }
      )
      intervalStepper(
        title: "At low battery",
        value: sampling.slowestIntervalSeconds,
        onChange: { delta in
          model.updateMetricsSampling { settings in
            settings.slowestIntervalSeconds += delta
          }
        }
      )
      .disabled(!sampling.isAdaptive)

      percentStepper(
        title: "Full-speed above",
        value: sampling.highBatteryPercent,
        onChange: { delta in
          model.updateMetricsSampling { settings in
            settings.highBatteryPercent += delta
          }
        }
      )
      .disabled(!sampling.isAdaptive)
      percentStepper(
        title: "Slowest at or below",
        value: sampling.lowBatteryPercent,
        onChange: { delta in
          model.updateMetricsSampling { settings in
            settings.lowBatteryPercent += delta
          }
        }
      )
      .disabled(!sampling.isAdaptive)
    }
  }

  private var effectiveInterval: TimeInterval {
    AdaptiveSamplingPolicy.interval(
      for: powerSource,
      isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      settings: sampling
    )
  }

  private var powerSourceText: String {
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return L10n.string("Low Power Mode") }
    switch powerSource {
    case .wallPower: return L10n.string("Wall power")
    case let .battery(percent): return L10n.format("Battery %d%%", percent)
    case .unknown: return L10n.string("No battery")
    }
  }

  private var powerSourceIcon: String {
    switch powerSource {
    case .wallPower: return "powerplug.fill"
    case let .battery(percent): return percent <= sampling.lowBatteryPercent
      ? "battery.25" : "battery.100"
    case .unknown: return "desktopcomputer"
    }
  }

  private func intervalStepper(
    title: String,
    value: TimeInterval,
    onChange: @escaping (TimeInterval) -> Void
  ) -> some View {
    HStack {
      Text(L10n.string(title))
      Spacer()
      Text(AdaptiveSamplingPolicy.describe(value))
        .font(.body.weight(.medium))
        .monospacedDigit()
        .frame(width: 52, alignment: .trailing)
      Stepper(
        L10n.string(title),
        onIncrement: { onChange(0.5) },
        onDecrement: { onChange(-0.5) }
      )
      .labelsHidden()
    }
  }

  private func percentStepper(
    title: String,
    value: Int,
    onChange: @escaping (Int) -> Void
  ) -> some View {
    HStack {
      Text(L10n.string(title))
      Spacer()
      Text("\(value)%")
        .font(.body.weight(.medium))
        .monospacedDigit()
        .frame(width: 52, alignment: .trailing)
      Stepper(
        L10n.string(title),
        onIncrement: { onChange(5) },
        onDecrement: { onChange(-5) }
      )
      .labelsHidden()
    }
  }

  // MARK: - Active actions

  private var activeActionsGroup: some View {
    SettingsGroup(spacing: 8) {
      HStack {
        Text(L10n.string("Currently on"))
          .font(.headline)
        Spacer()
        Button("Manage") { selectPane(.quickActions) }
          .buttonStyle(.link)
      }

      let active = quickActionService.catalogItems.filter { $0.state.isOn == true }
      if active.isEmpty {
        Text(L10n.string("No toggles are currently on."))
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        WrappingChips(items: active.map { ($0.id, $0.title, $0.systemImage) })
      }
    }
  }

  // MARK: - Checks

  private var checksGroup: some View {
    SettingsGroup(spacing: 8) {
      Text(L10n.string("Status"))
        .font(.headline)

      OverviewCheckRow(
        isHealthy: model.authorizationState.canReadEvents,
        title: "Calendar access",
        detail: model.authorizationState.canReadEvents
          ? L10n.string("Events are visible in the popover.")
          : L10n.string("Grant access to show events."),
        destination: .calendars,
        select: selectPane
      )

      OverviewCheckRow(
        isHealthy: powerHelper.registrationState.isEnabled,
        title: "Power Helper",
        detail: powerHelper.registrationState.detail,
        destination: .quickActions,
        select: selectPane
      )

      if syncService.isEntitled {
        OverviewCheckRow(
          isHealthy: syncService.status.isHealthy,
          title: "iCloud Sync",
          detail: syncService.status.title,
          destination: .iCloud,
          select: selectPane
        )
      }

      OverviewCheckRow(
        isHealthy: updateService.automaticUpdatesEnabled,
        title: "Automatic updates",
        detail: updateService.automaticUpdatesEnabled
          ? L10n.string("MenuCue checks for updates in the background.")
          : L10n.string("Automatic checks are off."),
        destination: .about,
        select: selectPane
      )
    }
  }
}

private struct OverviewMetricTile: View {
  let title: String
  let value: String
  let fraction: Double
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.string(title))
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .kerning(0.4)
      Text(value)
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
      MetricBar(fraction: fraction, tint: tint)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }
}

private struct OverviewCheckRow: View {
  let isHealthy: Bool
  let title: String
  let detail: String
  let destination: SettingsPane
  let select: (SettingsPane) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(isHealthy ? Color.green : Color.orange)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(L10n.string(title))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      Button(destination.title) { select(destination) }
        .buttonStyle(.link)
    }
    .padding(.vertical, 3)
  }
}

/// Simple flow layout for the "currently on" chips, so a long list wraps instead of
/// squeezing every chip to nothing.
private struct WrappingChips: View {
  let items: [(id: String, title: String, systemImage: String)]

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(items, id: \.id) { item in
        Label(item.title, systemImage: item.systemImage)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.accentColor.opacity(0.14), in: Capsule())
          .foregroundStyle(Color.accentColor)
      }
    }
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let rows = arrange(subviews: subviews, availableWidth: width)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(subviews: subviews, availableWidth: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(subviews: Subviews, availableWidth: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if !current.indices.isEmpty, needed > availableWidth {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
