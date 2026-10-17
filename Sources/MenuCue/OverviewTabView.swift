import Combine
import SwiftUI

struct OverviewTabView: View {
  @Environment(\.menuCueMotion) private var motion
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject private var popoverPresentation = PopoverPresentationState.shared
  @StateObject private var detail = SystemDetailService()
  @StateObject private var samplingController = VisibilityGate()
  @State private var detailPanelHeight: CGFloat = 0
  @State private var isEditing = false

  private static let detailPanelWidth: CGFloat = 260
  private static let detailPanelGap: CGFloat = 6

  var body: some View {
    PopoverHapticScrollView {
      VStack(spacing: PopoverMetrics.cardSpacing) {
        headerControlRow

        if isEditing {
          editingPanel
        }

        let widgets = model.settings.overviewWidgets.filter(\.isEnabled)
        ForEach(widgets) { widget in
          widgetView(for: widget.kind)
        }
      }
    }
    .overlayPreferenceValue(MetricDetailAnchorKey.self) { anchors in
      GeometryReader { proxy in
        if let target = detail.target, let anchor = anchors[target] {
          detailPanel(for: target, cardFrame: proxy[anchor], container: proxy.size)
        }
      }
      .allowsHitTesting(false)
    }
    .animation(motion.hoverAnimation, value: detail.target)
    .onAppear {
      samplingController.connect(
        to: popoverPresentation,
        onStart: {
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

  private var todayOverviewCard: some View {
    PopoverCard(title: L10n.string("Today"), systemImage: "calendar", tint: .red) {
      HStack(spacing: 8) {
        timeZoneMenu

        Button(L10n.string("Calendar")) {
          router.openPopover(tab: .calendar)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
      }
    } content: {
      TimelineView(.periodic(from: Date(), by: 1)) { context in
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(todayDateText(date: context.date))
                  .font(.system(size: 13, weight: .semibold))
                Text(currentTimeText(date: context.date))
                  .font(.system(size: 12, weight: .semibold, design: .rounded))
                  .monospacedDigit()
                  .foregroundStyle(Color.accentColor)
              }
              HStack(spacing: 6) {
                if let lunar = todayLunarText(date: context.date) {
                  Text(lunar)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Text(timeZoneSubtitle)
                  .font(.system(size: 10))
                  .foregroundStyle(.tertiary)
              }
            }
            Spacer()
            if let nextEvent = upcomingEvent(date: context.date) {
              VStack(alignment: .trailing, spacing: 2) {
                Text(nextEvent.title)
                  .font(.system(size: 11, weight: .medium))
                  .lineLimit(1)
                Text(eventTimeText(nextEvent, date: context.date))
                  .font(.system(size: 9.5))
                  .foregroundStyle(.secondary)
              }
            } else {
              Text(L10n.string("No upcoming events"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
          }

          let secondary = secondaryTimeZones
          if !secondary.isEmpty {
            Divider()
              .opacity(0.6)

            HStack(spacing: 8) {
              ForEach(secondary) { clock in
                Button {
                  model.updateSettings { $0.overviewTimeZoneID = clock.timeZone.identifier }
                } label: {
                  HStack(spacing: 4) {
                    Text(clock.flag)
                      .font(.system(size: 10))
                    Text(clock.title)
                      .font(.system(size: 10.5, weight: .medium))
                      .foregroundStyle(.secondary)
                    Text(timeText(for: clock.timeZone, date: context.date))
                      .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                      .monospacedDigit()
                      .foregroundStyle(.primary)

                    let offset = relativeOffsetString(
                      from: model.settings.overviewTimeZone,
                      to: clock.timeZone,
                      date: context.date
                    )
                    Text(offset)
                      .font(.system(size: 9))
                      .foregroundStyle(Color.accentColor)
                  }
                  .padding(.horizontal, 6)
                  .padding(.vertical, 3)
                  .background(Color.secondary.opacity(0.08))
                  .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
              }
              Spacer()
            }
          }
        }
      }
    }
  }

  private var timeZoneMenu: some View {
    Menu {
      ForEach(model.settings.clockTimeZones) { clock in
        Button {
          model.updateSettings { $0.overviewTimeZoneID = clock.timeZone.identifier }
        } label: {
          HStack {
            Text("\(clock.flag) \(clock.title) (\(clock.subtitle))")
            if clock.timeZone.identifier == model.settings.overviewTimeZoneID {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "globe")
          .font(.system(size: 9))
        Text(currentClockTimeZone?.title ?? TimeZoneCatalog.shortTitle(for: model.settings.overviewTimeZoneID))
          .font(.system(size: 10, weight: .medium))
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
      }
      .foregroundStyle(Color.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.secondary.opacity(0.10))
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var fusedTimeZones: [ClockTimeZone] {
    var result: [ClockTimeZone] = []
    if let primary = currentClockTimeZone {
      result.append(primary)
    } else if let custom = ClockTimeZone.custom(identifier: model.settings.overviewTimeZoneID) {
      result.append(custom)
    }
    for clock in model.settings.clockTimeZones {
      if !result.contains(where: { $0.timeZone.identifier == clock.timeZone.identifier }) {
        result.append(clock)
      }
      if result.count >= 3 { break }
    }
    return result
  }

  private var secondaryTimeZones: [ClockTimeZone] {
    fusedTimeZones.filter { $0.timeZone.identifier != model.settings.overviewTimeZoneID }
  }

  private func timeText(for timeZone: TimeZone, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  private func relativeOffsetString(from primary: TimeZone, to target: TimeZone, date: Date) -> String {
    let diffSeconds = target.secondsFromGMT(for: date) - primary.secondsFromGMT(for: date)
    let hours = diffSeconds / 3600
    let minutes = abs((diffSeconds % 3600) / 60)
    let sign = hours >= 0 ? "+" : ""
    let offsetStr = minutes == 0 ? "\(sign)\(hours)h" : "\(sign)\(hours)h\(minutes)m"

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = primary
    let primaryDay = cal.component(.day, from: date)
    cal.timeZone = target
    let targetDay = cal.component(.day, from: date)
    if targetDay > primaryDay {
      return "\(offsetStr) 明天"
    } else if targetDay < primaryDay {
      return "\(offsetStr) 昨天"
    }
    return offsetStr
  }
  // MARK: - Header Controls & Editing Mode

  private var headerControlRow: some View {
    HStack {
      Spacer()
      Button {
        withAnimation(motion.stateAnimation) {
          isEditing.toggle()
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: isEditing ? "checkmark.circle.fill" : "slider.horizontal.3")
            .font(.system(size: 11))
          Text(isEditing ? L10n.string("Done") : L10n.string("Customize"))
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(isEditing ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(isEditing ? 0.15 : 0.08))
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 4)
  }

  private var editingPanel: some View {
    PopoverCard(title: L10n.string("Edit Overview"), systemImage: "square.grid.2x2", tint: .blue) {
      Button(L10n.string("Manage Widgets in Settings")) {
        router.openSettings(pane: .panel)
      }
      .buttonStyle(.plain)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(Color.accentColor)
    } content: {
      VStack(spacing: 8) {
        ForEach(Array(model.settings.overviewWidgets.enumerated()), id: \.element.id) { index, widget in
          HStack(spacing: 8) {
            Image(systemName: widget.kind.systemImage)
              .font(.system(size: 12))
              .foregroundStyle(widget.kind.accentTint)
              .frame(width: 16)

            Text(widget.kind.title)
              .font(.system(size: 12, weight: .medium))

            Spacer()

            Toggle("", isOn: Binding(
              get: { widget.isEnabled },
              set: { _ in
                model.updateSettings { $0.toggleOverviewWidget(widget.kind) }
              }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            HStack(spacing: 4) {
              Button {
                guard index > 0 else { return }
                model.updateSettings {
                  $0.moveOverviewWidgets(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                }
              } label: {
                Image(systemName: "chevron.up")
                  .font(.system(size: 9, weight: .semibold))
              }
              .buttonStyle(.bordered)
              .controlSize(.mini)
              .disabled(index == 0)

              Button {
                guard index < model.settings.overviewWidgets.count - 1 else { return }
                model.updateSettings {
                  $0.moveOverviewWidgets(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                }
              } label: {
                Image(systemName: "chevron.down")
                  .font(.system(size: 9, weight: .semibold))
              }
              .buttonStyle(.bordered)
              .controlSize(.mini)
              .disabled(index == model.settings.overviewWidgets.count - 1)
            }
          }
          .padding(.vertical, 2)
          if index < model.settings.overviewWidgets.count - 1 {
            Divider().opacity(0.5)
          }
        }
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: - Widget Views

  @ViewBuilder
  private func widgetView(for kind: OverviewWidgetKind) -> some View {
    switch kind {
    case .today:
      todayOverviewCard
    case .systemMetrics:
      SystemMetricsCards(metrics: metrics, detail: detail)
    case .quickActions:
      quickActionsCard
    case .batteryFlow:
      batteryFlowWidgetCard
    case .processEnergy:
      processEnergyWidgetCard
    case .upcomingEvents:
      upcomingEventsWidgetCard
    }
  }

  private var quickActionsCard: some View {
    PopoverCard(title: L10n.string("Quick Actions"), systemImage: "bolt.fill", tint: .yellow) {
      Button(L10n.string("All")) { router.openPopover(tab: .actions) }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    } content: {
      PinnedQuickActionGrid(model: model)
    }
  }

  private var batteryFlowWidgetCard: some View {
    PopoverCard(title: L10n.string("Battery Flow"), systemImage: "battery.100percent", tint: .green) {
      Button(L10n.string("Power")) { router.openPopover(tab: .power) }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    } content: {
      if let battery = model.powerDiagnosticsService.battery {
        HStack(alignment: .firstTextBaseline) {
          Text("\(battery.percentage)%")
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .monospacedDigit()
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text(battery.isOnAC == true ? L10n.string("AC Power") : L10n.string("Battery Power"))
              .font(.system(size: 10.5, weight: .semibold))
            if let flow = battery.flow {
              Text(String(format: "%+.1f W", flow.watts))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(flow.watts < 0 ? .orange : .green)
            }
          }
        }
        if let flowState = PowerFlowState.make(battery: battery) {
          PowerFlowView(state: flowState)
        } else {
          MetricBar(fraction: Double(battery.percentage) / 100, tint: .green)
        }
      } else {
        CardPlaceholder(message: L10n.string("No internal battery"))
      }
    }
  }

  private var processEnergyWidgetCard: some View {
    PopoverCard(title: L10n.string("Process Energy"), systemImage: "flame.fill", tint: .orange) {
      Button(L10n.string("All")) { router.openPopover(tab: .power) }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    } content: {
      let entries = model.processEnergyService.entries.prefix(4)
      if entries.isEmpty {
        CardPlaceholder(message: L10n.string("No process energy sample"))
      } else {
        VStack(spacing: 5) {
          ForEach(Array(entries)) { entry in
            HStack(spacing: 6) {
              Text(entry.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
              Spacer(minLength: 6)
              Text(String(format: "%.1f", entry.energyImpact))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
            }
          }
        }
      }
    }
  }

  private var upcomingEventsWidgetCard: some View {
    PopoverCard(title: L10n.string("Upcoming Events"), systemImage: "clock.badge.checkmark", tint: .purple) {
      Button(L10n.string("Calendar")) { router.openPopover(tab: .calendar) }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    } content: {
      let events = Array(model.events.filter { $0.endDate > Date() }.prefix(3))
      if events.isEmpty {
        CardPlaceholder(message: L10n.string("No upcoming events"))
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(events) { event in
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                  .font(.system(size: 11.5, weight: .medium))
                  .lineLimit(1)
                Text(eventTimeText(event, date: Date()))
                  .font(.system(size: 9.5))
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if event.isAllDay {
                SettingsChip(L10n.string("All day"), prominent: false)
              }
            }
          }
        }
      }
    }
  }
  private var currentClockTimeZone: ClockTimeZone? {
    model.settings.clockTimeZones.first { $0.timeZone.identifier == model.settings.overviewTimeZoneID }
  }

  private var timeZoneSubtitle: String {
    let flag = currentClockTimeZone?.flag ?? TimeZoneCatalog.flag(for: model.settings.overviewTimeZoneID)
    let display = currentClockTimeZone?.subtitle ?? TimeZoneCatalog.displayName(for: model.settings.overviewTimeZoneID)
    return "\(flag) \(display)"
  }

  private func currentTimeText(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = model.settings.overviewTimeZone
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  private func todayDateText(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = model.settings.overviewTimeZone
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  private func todayLunarText(date: Date) -> String? {
    guard model.settings.showsLunarCalendar else { return nil }
    let info = LunarDateProvider(timeZone: model.settings.overviewTimeZone, locale: L10n.appLocale).info(for: date)
    return info?.compactText ?? info?.fullText
  }

  private func upcomingEvent(date: Date) -> CalendarEventInfo? {
    model.events.first { event in
      event.endDate > date
    }
  }

  private func eventTimeText(_ event: CalendarEventInfo, date: Date) -> String {
    if event.isAllDay { return L10n.string("All day") }
    let formatter = DateFormatter()
    formatter.timeZone = model.settings.overviewTimeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: event.startDate)
  }

  @ViewBuilder
  private func detailPanel(
    for target: MetricDetailTarget,
    cardFrame: CGRect,
    container: CGSize
  ) -> some View {
    let origin = StatusTabView.panelOrigin(
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
        .opacity(height > 0 ? 1 : 0)
    }
    .onPreferenceChange(MetricDetailHeightKey.self) { measured in
      detailPanelHeight = measured
    }
  }
}
