import Combine
import Foundation

/// A request that still counts when it repeats.
///
/// Two identical deep links in a row carry the same value, and a plain `@Published`
/// property would publish the first and swallow the second — which is why opening
/// Settings twice used to need the whole view tree rebuilt to be noticed. The sequence
/// number makes every request distinct, the same way `SwipeRelay.Command` distinguishes
/// two flicks in the same direction.
struct Sequenced<Value: Equatable>: Equatable {
  let value: Value
  let sequence: Int
}

/// Where the app is, and where something just asked it to go.
///
/// One object holds what used to be four view-local `@State` properties reached through
/// a chain of closures. Opening a surface is now a state change plus a request: the
/// state says which tab or pane to show, and the request is what `StatusBarController`
/// turns into a window on screen.
///
/// Deliberately free of AppKit: every deep link can be replayed in a test without a
/// window server.
@MainActor
final class AppRouter: ObservableObject {
  /// A surface something asked to have in front of the user.
  ///
  /// The associated value is the explicitly requested target, and `nil` means "wherever
  /// you already were" — a bare Settings… must not throw away the pane the user is on.
  enum Route: Equatable {
    case popover(PopoverTab?)
    case settings(SettingsPane?)
    case dashboard(DashboardSection?)
    case newEvent
  }

  /// A window that outlives its own close: both are `isReleasedWhenClosed = false`, so
  /// closing one only orders it out and the SwiftUI tree inside stays alive. Anything
  /// scoped to "while this window is up" has to watch this rather than `onDisappear`.
  enum Window: Hashable {
    case settings
    case dashboard
  }

  /// The popover tab on screen. `nil` until something selects one, which is what lets
  /// the popover open on the first tab of the user's own order.
  @Published var popoverTab: PopoverTab?
  @Published var settingsPane: SettingsPane = .menuBar
  @Published var dashboardSection: DashboardSection = .cpu
  @Published private(set) var route: Sequenced<Route>?
  @Published private(set) var visibleWindows: Set<Window> = []

  private var sequence = 0

  func openPopover(tab: PopoverTab? = nil) {
    if let tab {
      popoverTab = tab
    }
    send(.popover(tab))
  }

  func openSettings(pane: SettingsPane? = nil) {
    if let pane {
      settingsPane = pane
    }
    send(.settings(pane))
  }

  func openDashboard(section: DashboardSection? = nil) {
    if let section {
      dashboardSection = section
    }
    send(.dashboard(section))
  }

  func openNewEvent() {
    send(.newEvent)
  }

  /// Deep link written as a bare identifier, the way a build from before the settings
  /// reorganization named its panes. Unknown identifiers navigate nowhere: landing on
  /// an arbitrary pane would be worse than not moving.
  func open(identifier: String) {
    switch Self.route(forIdentifier: identifier) {
    case let .popover(tab):
      openPopover(tab: tab)
    case let .settings(pane):
      openSettings(pane: pane)
    case let .dashboard(section):
      openDashboard(section: section)
    case .newEvent:
      openNewEvent()
    case nil:
      break
    }
  }

  static func route(forIdentifier identifier: String) -> Route? {
    // The Dashboard was a settings pane once and is its own window now, so its old
    // identifier has to cross over to the other kind of destination.
    if identifier == "dashboard" {
      return .dashboard(nil)
    }
    guard let pane = SettingsPane.migrating(rawValue: identifier) else { return nil }
    return .settings(pane)
  }

  func setWindow(_ window: Window, visible: Bool) {
    if visible {
      visibleWindows.insert(window)
    } else {
      visibleWindows.remove(window)
    }
  }

  func isVisible(_ window: Window) -> Bool {
    visibleWindows.contains(window)
  }

  func visibility(of window: Window) -> AnyPublisher<Bool, Never> {
    $visibleWindows
      .map { $0.contains(window) }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }

  private func send(_ route: Route) {
    sequence += 1
    self.route = Sequenced(value: route, sequence: sequence)
  }
}
