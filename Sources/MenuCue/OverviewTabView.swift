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

  private static let detailPanelWidth: CGFloat = 260
  private static let detailPanelGap: CGFloat = 6

  var body: some View {
    PopoverHapticScrollView {
      VStack(spacing: PopoverMetrics.cardSpacing) {
        todayOverviewCard

        SystemMetricsCards(metrics: metrics, detail: detail)

        PopoverCard(title: L10n.string("Quick Actions"), systemImage: "bolt.fill", tint: .yellow) {
          Button(L10n.string("All")) { router.openPopover(tab: .actions) }
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
      Button(L10n.string("Calendar")) {
        router.openPopover(tab: .calendar)
      }
      .buttonStyle(.plain)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(Color.accentColor)
    } content: {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(todayDateText)
            .font(.system(size: 13, weight: .semibold))
          if let lunar = todayLunarText {
            Text(lunar)
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let nextEvent = upcomingEvent {
          VStack(alignment: .trailing, spacing: 2) {
            Text(nextEvent.title)
              .font(.system(size: 11, weight: .medium))
              .lineLimit(1)
            Text(eventTimeText(nextEvent))
              .font(.system(size: 9.5))
              .foregroundStyle(.secondary)
          }
        } else {
          Text(L10n.string("No upcoming events"))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var todayDateText: String {
    let formatter = DateFormatter()
    formatter.timeZone = model.settings.overviewTimeZone
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: Date())
  }

  private var todayLunarText: String? {
    guard model.settings.showsLunarCalendar else { return nil }
    let info = LunarDateProvider(timeZone: model.settings.overviewTimeZone, locale: L10n.appLocale).info(for: Date())
    return info?.compactText ?? info?.fullText
  }

  private var upcomingEvent: CalendarEventInfo? {
    let now = Date()
    return model.events.first { event in
      event.endDate > now
    }
  }

  private func eventTimeText(_ event: CalendarEventInfo) -> String {
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
