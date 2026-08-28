import Combine
import XCTest

@testable import MenuCue

@MainActor
final class AppRouterTests: XCTestCase {
  func testExplicitTargetsMoveTheStateAndPublishTheRoute() {
    let router = AppRouter()

    XCTAssertNil(router.popoverTab)
    XCTAssertEqual(router.settingsPane, .menuBar)
    XCTAssertEqual(router.dashboardSection, .cpu)
    XCTAssertNil(router.route)

    router.openSettings(pane: .power)
    XCTAssertEqual(router.settingsPane, .power)
    XCTAssertEqual(router.route?.value, .settings(.power))

    router.openDashboard(section: .network)
    XCTAssertEqual(router.dashboardSection, .network)
    XCTAssertEqual(router.route?.value, .dashboard(.network))

    router.openPopover(tab: .actions)
    XCTAssertEqual(router.popoverTab, .actions)
    XCTAssertEqual(router.route?.value, .popover(.actions))

    router.openNewEvent()
    XCTAssertEqual(router.route?.value, .newEvent)
  }

  /// The whole point of the rewrite: a settings entry point that names no pane must
  /// leave the user where they were, instead of resetting the open window to its first
  /// pane the way rebuilding the view tree did.
  func testOpeningWithoutATargetKeepsTheCurrentState() {
    let router = AppRouter()
    router.openSettings(pane: .trackpad)
    router.openDashboard(section: .memory)
    router.openPopover(tab: .calendar)

    router.openSettings()
    XCTAssertEqual(router.settingsPane, .trackpad)
    XCTAssertEqual(router.route?.value, .settings(nil))

    router.openDashboard()
    XCTAssertEqual(router.dashboardSection, .memory)
    XCTAssertEqual(router.route?.value, .dashboard(nil))

    router.openPopover()
    XCTAssertEqual(router.popoverTab, .calendar)
    XCTAssertEqual(router.route?.value, .popover(nil))
  }

  /// Two identical deep links in a row have to arrive as two requests. Without the
  /// sequence number the second is the same value as the first and is never observed,
  /// which is why the old code rebuilt the whole window to be noticed.
  func testRepeatingTheSameRequestIsStillObserved() {
    let router = AppRouter()
    var observed: [AppRouter.Route] = []
    let cancellable = router.$route
      .compactMap { $0 }
      .sink { observed.append($0.value) }

    router.openSettings(pane: .alerts)
    router.openSettings(pane: .alerts)
    router.openSettings(pane: .alerts)

    XCTAssertEqual(observed, [.settings(.alerts), .settings(.alerts), .settings(.alerts)])
    XCTAssertEqual(router.route?.sequence, 3)
    cancellable.cancel()
  }

  func testSequenceNumbersAreUniqueAcrossDestinations() {
    let router = AppRouter()
    var sequences: [Int] = []
    let cancellable = router.$route
      .compactMap { $0?.sequence }
      .sink { sequences.append($0) }

    router.openPopover(tab: .status)
    router.openSettings(pane: .general)
    router.openNewEvent()

    XCTAssertEqual(sequences, [1, 2, 3])
    cancellable.cancel()
  }

  /// A pane identifier written before the settings reorganization still has to land on
  /// whichever surface now owns it — including the Dashboard, which stopped being a
  /// settings pane and became a window.
  func testLegacyIdentifiersRouteToTheirNewOwner() {
    XCTAssertEqual(AppRouter.route(forIdentifier: "overview"), .settings(.panel))
    XCTAssertEqual(AppRouter.route(forIdentifier: "dateAndTime"), .settings(.menuBar))
    XCTAssertEqual(AppRouter.route(forIdentifier: "quickActions"), .settings(.actionCenter))
    XCTAssertEqual(AppRouter.route(forIdentifier: "notifications"), .settings(.alerts))
    XCTAssertEqual(AppRouter.route(forIdentifier: "language"), .settings(.general))
    XCTAssertEqual(AppRouter.route(forIdentifier: "trackpad"), .settings(.trackpad))
    XCTAssertEqual(AppRouter.route(forIdentifier: "dashboard"), .dashboard(nil))
    XCTAssertNil(AppRouter.route(forIdentifier: "nonsense"))
  }

  func testUnknownIdentifierNavigatesNowhere() {
    let router = AppRouter()
    router.openSettings(pane: .calendar)

    router.open(identifier: "nonsense")
    XCTAssertEqual(router.settingsPane, .calendar)
    XCTAssertEqual(router.route?.sequence, 1)

    router.open(identifier: "quickActions")
    XCTAssertEqual(router.settingsPane, .actionCenter)
    XCTAssertEqual(router.route?.sequence, 2)
  }

  func testWindowVisibilityPublishesOnlyChangesForTheWindowAskedAbout() {
    let router = AppRouter()
    var settingsVisibility: [Bool] = []
    let cancellable = router.visibility(of: .settings).sink { settingsVisibility.append($0) }

    router.setWindow(.dashboard, visible: true)
    router.setWindow(.settings, visible: true)
    router.setWindow(.settings, visible: true)
    XCTAssertTrue(router.isVisible(.settings))
    XCTAssertTrue(router.isVisible(.dashboard))

    router.setWindow(.settings, visible: false)
    XCTAssertFalse(router.isVisible(.settings))
    XCTAssertTrue(router.isVisible(.dashboard))

    XCTAssertEqual(settingsVisibility, [false, true, false])
    cancellable.cancel()
  }

  /// The trip a retained window actually makes: opened, closed, reopened without the
  /// pane ever changing, minimized, restored. Work scoped to that window — the trackpad
  /// preview, the `pmset` poll, the Dashboard samplers — has to start and stop once per
  /// visit, because `onAppear` fires at most once for a window that is only ordered out.
  func testWindowScopedWorkBalancesAcrossCloseReopenAndMiniaturize() {
    let router = AppRouter()
    let gate = VisibilityGate()
    var starts = 0
    var stops = 0
    gate.connect(
      to: router.visibility(of: .settings),
      onStart: { starts += 1 },
      onStop: { stops += 1 }
    )
    // Connecting while the window is closed must not start anything: a pane can be
    // selected on a window that is not on screen yet.
    XCTAssertEqual(starts, 0)

    router.setWindow(.settings, visible: true)
    XCTAssertEqual(starts, 1)

    router.setWindow(.settings, visible: false)
    router.setWindow(.settings, visible: true)
    XCTAssertEqual(starts, 2)
    XCTAssertEqual(stops, 1)

    router.setWindow(.settings, visible: false)
    router.setWindow(.settings, visible: true)
    XCTAssertEqual(starts, 3)
    XCTAssertEqual(stops, 2)
    XCTAssertTrue(gate.isActive)

    // The other window's comings and goings are none of this gate's business.
    router.setWindow(.dashboard, visible: true)
    router.setWindow(.dashboard, visible: false)
    XCTAssertEqual(starts, 3)
    XCTAssertEqual(stops, 2)

    // Leaving the pane while the window stays up stops the work exactly once, and
    // coming back to it starts it again.
    gate.disconnect()
    XCTAssertEqual(stops, 3)
    XCTAssertFalse(gate.isActive)

    gate.connect(
      to: router.visibility(of: .settings),
      onStart: { starts += 1 },
      onStop: { stops += 1 }
    )
    XCTAssertEqual(starts, 4)
    XCTAssertEqual(stops, 3)
  }

  /// The popover falls back to the first tab of the user's own order, so an untouched
  /// router must not claim a tab.
  func testPopoverTabStaysUnsetUntilSomethingSelectsOne() {
    let router = AppRouter()
    router.openPopover()
    XCTAssertNil(router.popoverTab)

    router.openPopover(tab: .power)
    XCTAssertEqual(router.popoverTab, .power)

    // A view that follows the user's own tab changes writes them straight back.
    router.popoverTab = .status
    XCTAssertEqual(router.popoverTab, .status)
  }
}
