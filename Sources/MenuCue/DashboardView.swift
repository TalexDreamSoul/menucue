import SwiftUI

/// The Dashboard pane: a pinned header and tab bar over a per-tab scroll view.
///
/// Owns both samplers, so sampling starts when this pane appears and stops when it
/// goes away. Opening Settings on any other pane never constructs this view, and so
/// never starts a timer — the Overview pane keeps rendering the cached snapshot.
struct DashboardView: View {
  @ObservedObject var model: AppModel
  let initialSection: DashboardSection
  /// Sideways flicks recognized by the AppKit container hosting the window.
  @ObservedObject var swipeRelay: SwipeRelay

  /// A denser window than the popover's 48: this chart is several times wider.
  @StateObject private var metrics = SystemMetricsService(historyCapacity: 120)
  @StateObject private var dashboard = DashboardMetricsService()
  @State private var section: DashboardSection
  /// Which way the next tab change travels, so the content slides toward the gesture.
  @State private var navigationDirection = 1
  @FocusState private var isFocused: Bool

  init(model: AppModel, initialSection: DashboardSection, swipeRelay: SwipeRelay) {
    self.model = model
    self.initialSection = initialSection
    self.swipeRelay = swipeRelay
    self._section = State(initialValue: initialSection)
  }

  /// Every entry point — click, arrow key, wheel, swipe — goes through here so they
  /// all animate identically.
  private func select(_ next: DashboardSection, direction: Int) {
    guard next != section else { return }
    navigationDirection = direction
    withAnimation(PopoverMotion.navigation) { section = next }
  }

  private func move(by offset: Int) {
    let tabs = DashboardSection.allCases
    guard let index = tabs.firstIndex(of: section) else { return }
    select(tabs[(index + offset + tabs.count) % tabs.count], direction: offset)
  }

  private var tabSelection: Binding<DashboardSection> {
    Binding(
      get: { section },
      set: { next in
        let tabs = DashboardSection.allCases
        guard let from = tabs.firstIndex(of: section), let to = tabs.firstIndex(of: next) else {
          return
        }
        select(next, direction: to >= from ? 1 : -1)
      }
    )
  }

  private var tabTransition: AnyTransition {
    let forward = navigationDirection >= 0
    return .asymmetric(
      insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
      removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
    )
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
      // Applied before retain() so the first timer already runs at the
      // battery-appropriate rate rather than being rebuilt one tick later.
      metrics.applySamplingSettings(model.settings.metricsSampling)
      metrics.retain()
      dashboard.attach(to: metrics)
      dashboard.activate(section)
    }
    .onDisappear {
      dashboard.deactivate()
      metrics.release()
    }
    .onChange(of: section) { next in
      dashboard.activate(next)
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
