import Combine
import SwiftUI

/// Everything that shapes the menu-bar popover: which tabs it has and in what order,
/// how often it samples this Mac, and how much motion it uses saying so.
struct PanelSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var powerSource: PowerSourceState = .unknown
  // Held as state so a body pass cannot re-create the publisher — a new one each time
  // tears down and reschedules the run loop timer.
  @State private var powerSourceTimer = Timer.publish(every: 15, on: .main, in: .common)
    .autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      popoverTabsGroup
      samplingGroup
      AnimationQualitySettingsView(model: model)
    }
    .onAppear {
      powerSource = PowerSourceReader.current()
    }
    .onReceive(powerSourceTimer) { _ in
      powerSource = PowerSourceReader.current()
    }
  }

  // MARK: - Popover tabs

  private var popoverTabsGroup: some View {
    SettingsGroup(spacing: 10) {
      Text(L10n.string("Popover tabs"))
        .font(.headline)

      List {
        ForEach(model.settings.popoverTabOrder) { tab in
          HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
              .foregroundStyle(.tertiary)
            Image(systemName: tab.systemImage)
              .foregroundStyle(.secondary)
              .frame(width: 18)
            Text(tab.title)
            Spacer()
          }
          .padding(.vertical, 2)
        }
        .onMove { source, destination in
          model.movePopoverTabs(fromOffsets: source, toOffset: destination)
        }
      }
      .frame(height: 142)

      Text(
        L10n.string(
          "Drag to set the tab order. The first tab opens after launch; horizontal swipes follow this order."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
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
}
