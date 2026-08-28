import SwiftUI

/// The Dashboard window's content: a pinned header and tab bar over a per-tab scroll
/// view.
///
/// Owns both samplers, so sampling starts when the window comes up and stops when it
/// goes away. Nothing else constructs it, so a Mac whose owner never opens the Dashboard
/// never starts these timers at all.
struct DashboardView: View {
  @Environment(\.menuCueMotion) private var motion
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  /// Sideways flicks recognized by the AppKit container hosting the window.
  @ObservedObject var swipeRelay: SwipeRelay

  /// A denser window than the popover's 48: this chart is several times wider.
  ///
  /// The window keeps this view alive between closes, so the 120 samples behind the
  /// charts survive closing and reopening it — the sampling itself does not, because
  /// `samplingGate` follows the window rather than the view.
  @StateObject private var metrics = SystemMetricsService(historyCapacity: 120)
  @StateObject private var dashboard = DashboardMetricsService()
  @StateObject private var samplingGate = VisibilityGate()
  /// Mirrors `router.dashboardSection`, and is what the transition animates against.
  @State private var section: DashboardSection = .cpu
  /// Which way the next tab change travels, so the content slides toward the gesture.
  @State private var navigationDirection = 1
  @FocusState private var isFocused: Bool

  /// Every entry point — click, arrow key, wheel, swipe — goes through here so they
  /// all animate identically.
  private func select(_ next: DashboardSection, direction: Int) {
    guard next != section else { return }
    navigationDirection = direction
    withAnimation(motion.navigationAnimation) { section = next }
  }

  private func move(by offset: Int) {
    let tabs = DashboardSection.allCases
    guard let index = tabs.firstIndex(of: section) else { return }
    select(tabs[(index + offset + tabs.count) % tabs.count], direction: offset)
  }

  private var tabSelection: Binding<DashboardSection> {
    Binding(
      get: { section },
      set: { next in select(next, direction: direction(to: next)) }
    )
  }

  /// Which way a jump to `next` travels, so the content slides the way the tab bar reads.
  private func direction(to next: DashboardSection) -> Int {
    let tabs = DashboardSection.allCases
    guard let from = tabs.firstIndex(of: section), let to = tabs.firstIndex(of: next) else {
      return 1
    }
    return to >= from ? 1 : -1
  }

  private var tabTransition: AnyTransition {
    motion.navigationTransition(forward: navigationDirection >= 0)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 5) {
          Label(L10n.string("Dashboard"), systemImage: "chart.line.uptrend.xyaxis")
            .font(.title2.weight(.semibold))
          Text(L10n.string("Live CPU, GPU, memory, storage, network, sensor and power readings."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        DashboardTabBar(selection: tabSelection)
      }
      .padding(.horizontal, 28)
      .padding(.top, 28)
      .padding(.bottom, 14)

      Divider().opacity(0.5)

      ScrollView {
        sectionContent
          .padding(.horizontal, 28)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(tabTransition)
      }
      .menuCueScrollBounceBehavior()
      // The outgoing and incoming tabs overlap while sliding.
      .clipped()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .focusable()
    .focused($isFocused)
    .menuCueFocusEffectDisabled()
    .menuCueHorizontalArrowNavigation { offset in
      move(by: offset)
    }
    .onChange(of: swipeRelay.command) { command in
      guard let command else { return }
      move(by: command.direction)
    }
    .onAppear {
      isFocused = true
      section = router.dashboardSection
      // Closing this window only orders it out, so sampling has to answer to the
      // window rather than to `onDisappear`, which need never run.
      samplingGate.connect(
        to: router.visibility(of: .dashboard),
        onStart: {
          // A deep link can arrive while the window is closed, so the tab is taken
          // from the router on the way back in rather than from what was last shown.
          section = router.dashboardSection
          // Applied before retain() so the first timer already runs at the
          // battery-appropriate rate rather than being rebuilt one tick later.
          metrics.applySamplingSettings(model.settings.metricsSampling)
          metrics.retain()
          // `deactivate` drops the frame subscription, so every visit attaches again.
          dashboard.attach(to: metrics)
          dashboard.activate(router.dashboardSection)
        },
        onStop: {
          dashboard.deactivate()
          metrics.release()
        }
      )
    }
    .onDisappear {
      samplingGate.disconnect()
    }
    .onChange(of: section) { next in
      // Nothing samples while the window is closed; the gate activates whichever tab
      // is current when it comes back.
      if samplingGate.isActive {
        dashboard.activate(next)
      }
      guard router.dashboardSection != next else { return }
      router.dashboardSection = next
    }
    // Both halves compare before writing, so a deep link and a click on the tab bar
    // settle in one pass instead of bouncing the value back and forth.
    .onChange(of: router.dashboardSection) { requested in
      select(requested, direction: direction(to: requested))
    }
    .onChange(of: model.settings.metricsSampling) { sampling in
      metrics.applySamplingSettings(sampling)
    }
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch section {
    case .cpu:
      DashboardCPUSection(metrics: metrics, dashboard: dashboard)
    case .gpu:
      DashboardGPUSection(metrics: metrics, dashboard: dashboard)
    case .memory:
      DashboardMemorySection(metrics: metrics, dashboard: dashboard)
    case .storage:
      DashboardStorageSection(metrics: metrics, dashboard: dashboard)
    case .network:
      DashboardNetworkSection(metrics: metrics, dashboard: dashboard)
    case .sensors:
      DashboardSensorsSection(metrics: metrics, dashboard: dashboard)
    case .power:
      DashboardPowerSection(
        model: model,
        diagnostics: model.powerDiagnosticsService,
        energy: model.processEnergyService)
    }
  }
}
