import Combine
import SwiftUI
import Foundation
import XCTest

@testable import MenuCue

final class DashboardSectionTests: XCTestCase {
  func testEveryMetricCardMapsToATab() {
    // Totality: a new MetricDetailTarget must be given a destination, not defaulted.
    let expected: [MetricDetailTarget: DashboardSection] = [
      .cpu: .cpu,
      .memory: .memory,
      .disk: .storage,
      .network: .network,
      .fan: .sensors,
    ]
    for target in MetricDetailTarget.allCases {
      XCTAssertEqual(
        DashboardSection(target: target), expected[target],
        "no Dashboard tab is mapped for the \(target.rawValue) card")
    }
    XCTAssertEqual(expected.count, MetricDetailTarget.allCases.count)
  }

  func testGPUIsReachableOnlyFromTheTabBar() {
    // GPU has no popover card, so nothing may deep-link to it.
    let linked = MetricDetailTarget.allCases.map(DashboardSection.init(target:))
    XCTAssertFalse(linked.contains(.gpu))
    XCTAssertTrue(DashboardSection.allCases.contains(.gpu))
  }

  /// The Dashboard holds no settings, so it is not a settings pane at all any more: it
  /// has its own window, reached through `AppRouter.openDashboard`. Menu Bar leads the
  /// sidebar, and is where an untouched router opens Settings.
  func testTheDashboardIsNoLongerASettingsPane() {
    XCTAssertEqual(SettingsPane.allCases.first, .menuBar)
    XCTAssertFalse(SettingsPane.allCases.map(\.rawValue).contains("dashboard"))
    XCTAssertNil(SettingsPane.migrating(rawValue: "dashboard"))
  }

  func testEachTabOnlyRequestsTheProbesItRenders() {
    XCTAssertEqual(DashboardSection.cpu.probes, [.perCore, .loadAverage, .thermals])
    XCTAssertEqual(DashboardSection.memory.probes, [.processes, .swap, .memoryPressure])
    XCTAssertEqual(DashboardSection.storage.probes, [.volumes, .diskOperations])
    XCTAssertEqual(DashboardSection.network.probes, [.interfaces])

    // Nothing may quietly pull the expensive process scan into another tab.
    for section in DashboardSection.allCases where section != .memory {
      XCTAssertFalse(
        section.probes.contains(.processes),
        "\(section.rawValue) must not enumerate every process")
    }
  }
}

final class DashboardModelTests: XCTestCase {
  func testHistoryDropsOldestBeyondCapacity() {
    var history = MetricHistory(capacity: 3)
    for value in [1.0, 2.0, 3.0, 4.0, 5.0] {
      history.append(value)
    }
    XCTAssertEqual(history.values, [3, 4, 5])
  }

  func testHistoryCapacityIsAtLeastOne() {
    var history = MetricHistory(capacity: 0)
    history.append(7)
    history.append(8)
    XCTAssertEqual(history.values, [8])
  }

  func testPressureDecodesOnlyTheLevelsTheKernelReports() {
    XCTAssertEqual(MemoryPressureLevel.decode(1), .normal)
    XCTAssertEqual(MemoryPressureLevel.decode(2), .warning)
    XCTAssertEqual(MemoryPressureLevel.decode(4), .critical)
    // 3 sits between warning and critical but is not a documented value; guessing
    // either way would show a severity the kernel never reported.
    XCTAssertNil(MemoryPressureLevel.decode(3))
    XCTAssertNil(MemoryPressureLevel.decode(0))
    XCTAssertNil(MemoryPressureLevel.decode(-1))
  }

  func testSwapFractionSurvivesAnUnusedSwapFile() {
    let unused = SwapUsage(used: 0, total: 0, isEncrypted: false)
    XCTAssertEqual(unused.fraction, 0)
    XCTAssertFalse(unused.isInUse)

    let half = SwapUsage(used: 512, total: 1_024, isEncrypted: true)
    XCTAssertEqual(half.fraction, 0.5, accuracy: 0.0001)
    XCTAssertTrue(half.isInUse)
  }

  func testVolumeFreeSpaceNeverUnderflows() {
    // Read-only DMG mounts legitimately report used == total.
    let full = VolumeUsage(
      path: "/Volumes/Installer", name: "Installer", format: "Mac OS Extended",
      used: 1_000, total: 1_000, isInternal: false)
    XCTAssertEqual(full.free, 0)
    XCTAssertEqual(full.fraction, 1)

    // A capacity reported smaller than usage must not wrap around UInt64.
    let inconsistent = VolumeUsage(
      path: "/", name: "Macintosh HD", format: "APFS",
      used: 2_000, total: 1_000, isInternal: true)
    XCTAssertEqual(inconsistent.free, 0)
    XCTAssertEqual(inconsistent.fraction, 1)
  }
}

final class DashboardProbeTests: XCTestCase {
  func testPerCoreLoadIsComputedFromDeltas() throws {
    let previous = [
      CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
      CPUTicks(user: 200, system: 100, idle: 700, nice: 0),
    ]
    let current = [
      CPUTicks(user: 200, system: 100, idle: 1_700, nice: 0),
      CPUTicks(user: 600, system: 300, idle: 1_100, nice: 0),
    ]

    let loads = try XCTUnwrap(DashboardProbe.perCoreLoad(from: previous, to: current))
    XCTAssertEqual(loads.count, 2)
    // Core 0: 100 user + 50 system out of 1000 elapsed ticks.
    XCTAssertEqual(loads[0].busy, 0.15, accuracy: 0.0001)
    // Core 1: 400 user + 200 system out of 1000.
    XCTAssertEqual(loads[1].busy, 0.6, accuracy: 0.0001)
  }

  func testPerCoreLoadRejectsIncomparableReads() {
    let ticks = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]

    // No baseline yet.
    XCTAssertNil(DashboardProbe.perCoreLoad(from: [], to: ticks))
    // Core count changed between reads, so the pairing would be meaningless.
    XCTAssertNil(DashboardProbe.perCoreLoad(from: ticks, to: ticks + ticks))
    // Counters did not advance.
    XCTAssertNil(DashboardProbe.perCoreLoad(from: ticks, to: ticks))
  }

  func testRateIgnoresACounterReset() {
    XCTAssertEqual(DashboardProbe.rate(from: 100, to: 200, elapsed: 2), 50, accuracy: 0.0001)
    // A counter that went backwards has been reset; reporting a huge negative or
    // wrapped rate would be worse than reporting nothing happened.
    XCTAssertEqual(DashboardProbe.rate(from: 200, to: 100, elapsed: 2), 0)
    XCTAssertEqual(DashboardProbe.rate(from: 100, to: 200, elapsed: 0), 0)
  }

  func testCoreTopologyAlwaysCoversTheRequestedCoreCount() {
    // Whatever the machine reports, callers index this array by core, so a short
    // array would be a crash waiting to happen.
    for count in [0, 1, 8, 14] {
      XCTAssertEqual(DashboardProbe.coreTopology(coreCount: count).count, count)
    }
  }

  func testLiveTopologyMatchesTheReportedCoreCount() throws {
    let ticks = DashboardProbe.perCoreTicks()
    try XCTSkipIf(ticks.isEmpty, "host_processor_info reported no cores")
    let topology = DashboardProbe.coreTopology(coreCount: ticks.count)
    XCTAssertEqual(topology.count, ticks.count)

    // Either every core is attributed, or none is — a partial split would mean some
    // cores are labelled with a cluster they may not belong to.
    let unspecified = topology.filter { $0 == .unspecified }.count
    XCTAssertTrue(
      unspecified == 0 || unspecified == topology.count,
      "topology is partially resolved: \(topology)")
  }
}

final class DashboardProcessListTests: XCTestCase {
  private let entries = [
    ProcessMemoryEntry(pid: 1, name: "node", residentBytes: 12_000),
    ProcessMemoryEntry(pid: 2, name: "Google Chrome", residentBytes: 5_000),
    ProcessMemoryEntry(pid: 3, name: "Google Chrome Helper (Renderer)", residentBytes: 5_000),
    ProcessMemoryEntry(pid: 4, name: "OrbStack", residentBytes: 2_600),
    ProcessMemoryEntry(pid: 5, name: "Orca", residentBytes: 1_500),
    ProcessMemoryEntry(pid: 6, name: "workerd", residentBytes: 760),
  ]

  func testPopoverPanelShowsAGlanceOfThree() {
    let ranked = SystemDetailProbe.rank(entries, limit: 3)
    XCTAssertEqual(ranked.count, 3)
    // Helpers still fold into their app before the list is truncated, otherwise the
    // top three would be wrong rather than merely short.
    XCTAssertEqual(ranked.map(\.name), ["node", "Google Chrome", "OrbStack"])
    XCTAssertEqual(ranked[1].residentBytes, 10_000)
  }

  func testDashboardAsksForALongerList() {
    let ranked = SystemDetailProbe.rank(entries, limit: 10)
    XCTAssertEqual(ranked.count, 5, "five distinct apps remain after helpers are folded")
    XCTAssertEqual(ranked.last?.name, "workerd")
  }

  func testTheHoverPanelDefaultsToThree() {
    // The popover consumer calls this with no argument.
    XCTAssertLessThanOrEqual(SystemDetailProbe.topMemoryProcesses().count, 3)
  }
}

final class DashboardHistoryCapacityTests: XCTestCase {
  func testPopoverKeepsItsOriginalWindow() {
    let service = SystemMetricsService(defaults: emptyDefaults())
    XCTAssertEqual(service.historyCapacity, 48)
    XCTAssertEqual(SystemMetricsService.historyCapacity, 48)
  }

  func testDashboardCanAskForADenserWindow() {
    let service = SystemMetricsService(historyCapacity: 120, defaults: emptyDefaults())
    XCTAssertEqual(service.historyCapacity, 120)
  }

  func testRestoredCacheIsTrimmedToThisInstancesWindow() throws {
    let defaults = emptyDefaults()
    let cache = SystemMetricsService.Cache(
      savedAt: Date(),
      snapshot: SystemMetricsSnapshot(),
      cpuHistory: Array(repeating: CPULoadSample(), count: 200)
    )
    defaults.set(try JSONEncoder().encode(cache), forKey: SystemMetricsService.cacheKey)

    let service = SystemMetricsService(historyCapacity: 12, defaults: defaults)
    XCTAssertEqual(service.cpuHistory.count, 12)
  }

  private func emptyDefaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: "DashboardHistoryCapacityTests")!
    suite.removePersistentDomain(forName: "DashboardHistoryCapacityTests")
    return suite
  }
}

final class SwipeRecognizerTests: XCTestCase {
  func testADeliberateFlickAdvancesOneTab() {
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0), .pass)
    // Fingers moving left push content left, revealing the tab to the right.
    XCTAssertEqual(
      recognizer.consume(deltaX: -15, deltaY: 0, phase: .changed, isPrecise: true, now: 0.01),
      .consume)
    XCTAssertEqual(
      recognizer.consume(deltaX: -15, deltaY: 0, phase: .changed, isPrecise: true, now: 0.02),
      .navigate(1))
  }

  func testFlickingTheOtherWayGoesBack() {
    var recognizer = SwipeRecognizer()
    _ = recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0)
    XCTAssertEqual(
      recognizer.consume(deltaX: 40, deltaY: 0, phase: .changed, isPrecise: true, now: 0.01),
      .navigate(-1))
  }

  func testOneGestureOnlyEverMovesOneTab() {
    var recognizer = SwipeRecognizer()
    _ = recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0)
    XCTAssertEqual(
      recognizer.consume(deltaX: -40, deltaY: 0, phase: .changed, isPrecise: true, now: 0.01),
      .navigate(1))
    // A long flick keeps delivering deltas; they must not race through every tab.
    for step in 0..<10 {
      XCTAssertEqual(
        recognizer.consume(
          deltaX: -40, deltaY: 0, phase: .changed, isPrecise: true, now: 0.02 + Double(step) * 0.01),
        .consume)
    }
    // Inertia after the fingers lift must not fire either.
    XCTAssertEqual(
      recognizer.consume(deltaX: -80, deltaY: 0, phase: .momentum, isPrecise: true, now: 0.2),
      .consume)
  }

  func testTheNextGestureIsArmedAgain() {
    var recognizer = SwipeRecognizer()
    _ = recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0)
    XCTAssertEqual(
      recognizer.consume(deltaX: -40, deltaY: 0, phase: .changed, isPrecise: true, now: 0.01),
      .navigate(1))
    XCTAssertEqual(
      recognizer.consume(deltaX: 0, deltaY: 0, phase: .ended, isPrecise: true, now: 0.2), .pass)
    _ = recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0.3)
    XCTAssertEqual(
      recognizer.consume(deltaX: -40, deltaY: 0, phase: .changed, isPrecise: true, now: 0.31),
      .navigate(1))
  }

  func testVerticalScrollingIsLeftAlone() {
    var recognizer = SwipeRecognizer()
    _ = recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0)
    // A real vertical scroll always drifts a little sideways; it must still scroll.
    for step in 0..<20 {
      XCTAssertEqual(
        recognizer.consume(
          deltaX: 3, deltaY: 30, phase: .changed, isPrecise: true, now: Double(step) * 0.01),
        .pass,
        "a vertical scroll was swallowed at step \(step)")
    }
  }

  func testAWheelFiresOncePerDetentNotPerEvent() {
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(
      recognizer.consume(deltaX: -3, deltaY: 0, phase: .none, isPrecise: false, now: 1),
      .navigate(1))
    // Same detent, still inside the debounce window.
    XCTAssertEqual(
      recognizer.consume(deltaX: -3, deltaY: 0, phase: .none, isPrecise: false, now: 1.1),
      .consume)
    XCTAssertEqual(
      recognizer.consume(deltaX: -3, deltaY: 0, phase: .none, isPrecise: false, now: 1.5),
      .navigate(1))
  }

  func testAPhaselessTrackpadStillWorks() {
    // Some devices report precise deltas with no phase at all.
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(
      recognizer.consume(deltaX: -30, deltaY: 2, phase: .none, isPrecise: true, now: 0),
      .navigate(1))
  }
}

@MainActor
final class PopoverSwipeContainerTests: XCTestCase {
  func testContainerOptsIntoHorizontalForwardingOnly() throws {
    let controller = SwipeForwardingController(rootView: Text("x").frame(width: 360, height: 620))
    _ = controller.view
    controller.viewDidLoad()
    let container = try XCTUnwrap(controller.view as? SwipeForwardingView)

    // This opt-in is the entire mechanism: NSScrollView only forwards an axis it was
    // asked for. Claiming the vertical axis too would steal ordinary scrolling.
    XCTAssertTrue(container.wantsForwardedScrollEvents(for: .horizontal))
    XCTAssertFalse(container.wantsForwardedScrollEvents(for: .vertical))
  }

  func testSwiftUIContentIsAChildOfTheContainer() throws {
    let controller = SwipeForwardingController(rootView: Text("x").frame(width: 360, height: 620))
    _ = controller.view
    controller.viewDidLoad()

    // The container has to be an *ancestor* of the scroll views, or nothing is
    // forwarded to it.
    XCTAssertEqual(controller.children.count, 1)
    let hosted = try XCTUnwrap(controller.children.first?.view)
    XCTAssertTrue(controller.view.subviews.contains { $0 === hosted })
  }

  func testInjectedRelayIsSharedWithTheContainer() throws {
    let relay = SwipeRelay()
    let controller = SwipeForwardingController(
      rootView: Text("x").frame(width: 360, height: 620),
      relay: relay
    )
    _ = controller.view
    controller.viewDidLoad()
    let container = try XCTUnwrap(controller.view as? SwipeForwardingView)

    XCTAssertTrue(controller.relay === relay)
    XCTAssertTrue(container.relay === relay)
  }

  func testRepeatedSwipesInTheSameDirectionAreEachObserved() {
    let relay = SwipeRelay()
    var observed: [Int] = []
    let cancellable = relay.$command.sink { command in
      if let command { observed.append(command.direction) }
    }
    relay.send(1)
    relay.send(1)
    relay.send(-1)
    cancellable.cancel()

    // Publishing the bare direction would drop the second swipe as a duplicate.
    XCTAssertEqual(observed, [1, 1, -1])
  }
}

@MainActor
final class SettingsWindowSizingTests: XCTestCase {
  /// Stands in for a settings pane whose content is far taller than the window.
  private var tallPane: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) { Text("Dashboard").font(.title2) }.padding(28)
      Divider()
      ScrollView {
        VStack(spacing: 12) {
          ForEach(0..<50, id: \.self) { Text("row \($0)").frame(maxWidth: .infinity, minHeight: 40) }
        }
        .padding(20)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func fittingHeight(_ view: some View) -> CGFloat {
    NSHostingController(rootView: AnyView(view)).view.fittingSize.height
  }

  func testDroppingTheIdealHeightMakesTheWindowAskForTheWholeContent() {
    // `NSHostingController` reports the SwiftUI ideal size as the window's fitting
    // size. With only a max, that ideal is the content's full height, so the hosting
    // view is laid out taller than the window: the scroll view then has nothing to
    // scroll and the overflow is silently clipped by the window edge.
    let withoutIdeal = fittingHeight(tallPane.frame(maxWidth: .infinity, maxHeight: .infinity))
    XCTAssertGreaterThan(withoutIdeal, 2_000, "content height leaked into the fitting size")

    let withIdeal = fittingHeight(
      tallPane.frame(
        minWidth: 720, idealWidth: 900, maxWidth: .infinity,
        minHeight: 540, idealHeight: 680, maxHeight: .infinity))
    XCTAssertEqual(withIdeal, 680, "the ideal height must be what the window is sized to")
  }

  func testMinIdealAndMaxAreAllRequired() {
    // min+ideal alone bounds the window but cannot grow with it; this documents that
    // adding max does not disturb the fitting size the window is built from.
    let withoutMax = fittingHeight(
      tallPane.frame(minWidth: 720, idealWidth: 900, minHeight: 540, idealHeight: 680))
    let withMax = fittingHeight(
      tallPane.frame(
        minWidth: 720, idealWidth: 900, maxWidth: .infinity,
        minHeight: 540, idealHeight: 680, maxHeight: .infinity))
    XCTAssertEqual(withoutMax, withMax)
  }
}

final class DiscreteSwipeTests: XCTestCase {
  /// Reproduces exactly what a real trackpad logged with "swipe between pages" on:
  /// one event per flick, phase `.began`, normalized ±1 delta, no `.changed` at all.
  func testAPageSwipeArrivesAsASingleBeganEvent() {
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(
      recognizer.consume(deltaX: -1, deltaY: 0, phase: .began, isPrecise: true, now: 0),
      .navigate(1))
  }

  func testTheOppositeFlickGoesBack() {
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(
      recognizer.consume(deltaX: 1, deltaY: 0, phase: .began, isPrecise: true, now: 0),
      .navigate(-1))
  }

  func testAlternatingFlicksEachRegister() {
    // The captured log showed -1, +1, -1, +1 as the user flicked back and forth.
    var recognizer = SwipeRecognizer()
    var moves: [Int] = []
    for (index, dx) in [-1.0, 1.0, -1.0, 1.0].enumerated() {
      let outcome = recognizer.consume(
        deltaX: dx, deltaY: 0, phase: .began, isPrecise: true, now: Double(index))
      if case let .navigate(step) = outcome { moves.append(step) }
    }
    XCTAssertEqual(moves, [1, -1, 1, -1])
  }

  func testOneFlickDoesNotFireTwice() {
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(
      recognizer.consume(deltaX: -1, deltaY: 0, phase: .began, isPrecise: true, now: 0),
      .navigate(1))
    // A repeat inside the debounce window is the same flick being re-delivered.
    XCTAssertEqual(
      recognizer.consume(deltaX: -1, deltaY: 0, phase: .began, isPrecise: true, now: 0.1),
      .consume)
  }

  func testTheStartOfAnOrdinaryScrollIsNotAFlick() {
    // A real two-finger scroll opens with deltas near zero and builds up later.
    var recognizer = SwipeRecognizer()
    XCTAssertEqual(
      recognizer.consume(deltaX: 0, deltaY: 0, phase: .began, isPrecise: true, now: 0), .pass)
    XCTAssertEqual(
      recognizer.consume(deltaX: 0.4, deltaY: 0, phase: .began, isPrecise: true, now: 0), .pass)
  }

  func testADiagonalScrollStartIsNotAFlick() {
    var recognizer = SwipeRecognizer()
    // Sideways drift while starting a vertical scroll must still scroll.
    XCTAssertEqual(
      recognizer.consume(deltaX: -2, deltaY: 6, phase: .began, isPrecise: true, now: 0), .pass)
  }
}
