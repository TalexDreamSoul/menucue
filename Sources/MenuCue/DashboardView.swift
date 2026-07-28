import SwiftUI

/// The Dashboard pane: a pinned header and tab bar over a per-tab scroll view.
///
/// Owns both samplers, so sampling starts when this pane appears and stops when it
/// goes away. Opening Settings on any other pane never constructs this view, and so
/// never starts a timer — the Overview pane keeps rendering the cached snapshot.
struct DashboardView: View {
  @ObservedObject var model: AppModel
  let initialSection: DashboardSection

  /// A denser window than the popover's 48: this chart is several times wider.
  @StateObject private var metrics = SystemMetricsService(historyCapacity: 120)
  @StateObject private var dashboard = DashboardMetricsService()
  @State private var section: DashboardSection

  init(model: AppModel, initialSection: DashboardSection) {
    self.model = model
    self.initialSection = initialSection
    self._section = State(initialValue: initialSection)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 5) {
          Label(L10n.string("Dashboard"), systemImage: "chart.line.uptrend.xyaxis")
            .font(.title2.weight(.semibold))
          Text(L10n.string("Live CPU, GPU, memory, storage, network, and sensor readings."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        DashboardTabBar(selection: $section)
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
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear {
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
    .onChange(of: section) { _, next in
      dashboard.activate(next)
    }
    .onChange(of: model.settings.metricsSampling) { _, sampling in
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
    }
  }
}
