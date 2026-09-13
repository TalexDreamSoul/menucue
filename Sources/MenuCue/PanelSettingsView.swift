import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Everything that shapes the menu-bar popover: which tabs it has and in what order,
/// how often it samples this Mac, and where the animation-quality control lives now.
struct PanelSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var powerSource: PowerSourceState = .unknown
  /// The row a drag started on, so a drop knows what to move. SwiftUI hands the drop
  /// target the item providers, not the row the drag came from.
  @State private var draggedTab: PopoverTab?
  // Held as state so a body pass cannot re-create the publisher — a new one each time
  // tears down and reschedules the run loop timer.
  @State private var powerSourceTimer = Timer.publish(every: 15, on: .main, in: .common)
    .autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      popoverTabsCard
      samplingCard
      animationMovedCard
    }
    .onAppear {
      powerSource = PowerSourceReader.current()
    }
    .onReceive(powerSourceTimer) { _ in
      powerSource = PowerSourceReader.current()
    }
  }

  // MARK: - Popover tabs

  private var popoverTabsCard: some View {
    SettingsCard(
      L10n.string("Popover tabs"),
      desc: L10n.string(
        "Drag to set the tab order. The first tab opens after launch; horizontal swipes follow this order."
      ),
      action: {
        SettingsChip(L10n.format("%d tabs · all shown", model.settings.popoverTabOrder.count))
      }
    ) {
      SettingsTable(columns: [
        SettingsTableColumn(L10n.string("Tab"), weight: 170),
        SettingsTableColumn(L10n.string("Description"), weight: 340),
        SettingsTableColumn(L10n.string("Order"), weight: 78, alignment: .trailing),
      ]) {
        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
          tabRow(tab, isFirst: index == 0)
        }
      }
    }
  }

  private var tabs: [PopoverTab] { model.settings.popoverTabOrder }

  private func tabRow(_ tab: PopoverTab, isFirst: Bool) -> some View {
    SettingsTableRow {
      HStack(spacing: 8) {
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 13))
          .foregroundStyle(.tertiary)
        Image(systemName: tab.systemImage)
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 18)
        HStack(spacing: 4) {
          Text(tab.title)
            .font(.system(size: 13, weight: .medium))
          if isFirst {
            SettingsChip(L10n.string("Default"), prominent: true)
              .padding(.leading, -4)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(summary(for: tab))
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .help(summary(for: tab))
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 6) {
        orderButton(for: tab, offset: -1, systemImage: "chevron.up")
        orderButton(for: tab, offset: 1, systemImage: "chevron.down")
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .onDrag {
      draggedTab = tab
      return NSItemProvider(object: tab.rawValue as NSString)
    }
    .onDrop(of: [.text], delegate: TabOrderDropDelegate(target: tab, dragged: $draggedTab) { dragged in
      move(dragged, onto: tab)
    })
  }

  /// Reorders the dragged row onto the row it was dropped on. `toOffset` is read against
  /// the list with the dragged row already taken out, so a downward move lands one place
  /// past the row it was dropped on.
  private func move(_ dragged: PopoverTab, onto target: PopoverTab) {
    guard
      let origin = tabs.firstIndex(of: dragged),
      let destination = tabs.firstIndex(of: target),
      origin != destination
    else { return }
    model.movePopoverTabs(
      fromOffsets: IndexSet(integer: origin),
      toOffset: destination > origin ? destination + 1 : destination
    )
  }

  /// The design document's one-line description of what each tab shows.
  private func summary(for tab: PopoverTab) -> String {
    switch tab {
    case .status: return L10n.string("CPU / Memory / Disk / Network + quick actions")
    case .calendar: return L10n.string("Month view and recent events")
    case .power: return L10n.string("Energy use and wake")
    case .actions: return L10n.string("Pinned actions and search")
    }
  }

  private func orderButton(for tab: PopoverTab, offset: Int, systemImage: String) -> some View {
    let title = offset < 0 ? L10n.string("Move up") : L10n.string("Move down")
    return Button {
      move(tab, by: offset)
    } label: {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(!canMove(tab, by: offset))
    .help(title)
    .accessibilityLabel(title)
  }

  private func canMove(_ tab: PopoverTab, by offset: Int) -> Bool {
    guard let index = tabs.firstIndex(of: tab) else { return false }
    return tabs.indices.contains(index + offset)
  }

  private func move(_ tab: PopoverTab, by offset: Int) {
    guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index + offset) else { return }
    // `toOffset` is read against the list with the moved row already removed, so a
    // downward move lands one place past the neighbour it swaps with.
    model.movePopoverTabs(
      fromOffsets: IndexSet(integer: index),
      toOffset: offset > 0 ? index + 2 : index - 1
    )
  }

  // MARK: - Sampling

  private var sampling: MetricsSamplingSettings { model.settings.metricsSampling }

  private var samplingCard: some View {
    SettingsCard(
      L10n.string("Sampling"),
      desc: L10n.string(
        "Adaptive sampling runs fastest on wall power and eases off as the battery drains, so a long unplugged session costs less."
      )
    ) {
      SettingsRows {
        SettingsRowToggle(
          L10n.string("Adapt sampling rate to battery level"),
          isOn: Binding(
            get: { sampling.isAdaptive },
            set: { value in model.updateMetricsSampling { $0.isAdaptive = value } }
          )
        )

        SettingsRow(L10n.string("Current")) {
          HStack(spacing: 6) {
            SettingsChip(powerSourceText, systemImage: powerSourceIcon)
            SettingsChip(
              L10n.format("Now sampling every %@", AdaptiveSamplingPolicy.describe(effectiveInterval)),
              systemImage: "activity",
              prominent: true
            )
          }
        }

        intervalStepper(
          title: L10n.string("On wall power / full battery"),
          desc: L10n.string("0.5–30 seconds, in 0.5-second steps."),
          value: sampling.fastestIntervalSeconds,
          onChange: { delta in
            model.updateMetricsSampling { settings in
              settings.fastestIntervalSeconds += delta
            }
          }
        )
        intervalStepper(
          title: L10n.string("At low battery"),
          desc: L10n.string("0.5–30 seconds; never shorter than the fastest interval."),
          value: sampling.slowestIntervalSeconds,
          onChange: { delta in
            model.updateMetricsSampling { settings in
              settings.slowestIntervalSeconds += delta
            }
          }
        )
        .disabled(!sampling.isAdaptive)

        percentStepper(
          title: L10n.string("Full-speed above"),
          desc: L10n.string("5%–95%; must stay above the low-battery threshold."),
          value: sampling.highBatteryPercent,
          onChange: { delta in
            model.updateMetricsSampling { settings in
              settings.highBatteryPercent += delta
            }
          }
        )
        .disabled(!sampling.isAdaptive)

        percentStepper(
          title: L10n.string("Slowest at or below"),
          desc: L10n.string("5%–95%; must stay below the full-speed threshold."),
          value: sampling.lowBatteryPercent,
          onChange: { delta in
            model.updateMetricsSampling { settings in
              settings.lowBatteryPercent += delta
            }
          }
        )
        .disabled(!sampling.isAdaptive)

        if !sampling.isAdaptive {
          SettingsRow(
            L10n.string("When adaptive sampling is off"),
            desc: L10n.string(
              "The four values above stop applying; the popover samples at a fixed interval."
            )
          ) {
            SettingsChip(
              L10n.format(
                "Fixed %@",
                AdaptiveSamplingPolicy.describe(sampling.fastestIntervalSeconds)
              )
            )
          }
        }
      }
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
    desc: String,
    value: TimeInterval,
    onChange: @escaping (TimeInterval) -> Void
  ) -> some View {
    SettingsRow(title, desc: desc) {
      HStack(spacing: 10) {
        Text(AdaptiveSamplingPolicy.describe(value))
          .font(.system(size: 12))
          .monospacedDigit()
          .frame(width: 52, alignment: .trailing)
        Stepper(
          title,
          onIncrement: { onChange(0.5) },
          onDecrement: { onChange(-0.5) }
        )
        .labelsHidden()
      }
    }
  }

  private func percentStepper(
    title: String,
    desc: String,
    value: Int,
    onChange: @escaping (Int) -> Void
  ) -> some View {
    SettingsRow(title, desc: desc) {
      HStack(spacing: 10) {
        Text("\(value)%")
          .font(.system(size: 12))
          .monospacedDigit()
          .frame(width: 52, alignment: .trailing)
        Stepper(
          title,
          onIncrement: { onChange(5) },
          onDecrement: { onChange(-5) }
        )
        .labelsHidden()
      }
    }
  }

  // MARK: - Animation quality

  /// The animation-quality control affects the whole app and the settings window, so the
  /// design document moves it to General › Appearance rather than duplicating it here.
  private var animationMovedCard: some View {
    SettingsCard(L10n.string("Animation Effects Moved to General › Appearance"), tone: .inset) {
      SettingsRows {
        SettingsPaneLinkRow(
          L10n.string("Animation effects"),
          desc: L10n.string("It affects the whole app and the settings window, not just the panel."),
          destination: .general,
          actionTitle: L10n.string("Open General")
        )
      }
    }
  }
}

/// Reorders the popover tabs when one row is dropped on another. The dragged row is kept
/// in the pane's state because the drop callback is handed item providers, not the row
/// the drag started from.
private struct TabOrderDropDelegate: DropDelegate {
  let target: PopoverTab
  @Binding var dragged: PopoverTab?
  let drop: (PopoverTab) -> Void

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    defer { dragged = nil }
    guard let dragged, dragged != target else { return false }
    drop(dragged)
    return true
  }
}
