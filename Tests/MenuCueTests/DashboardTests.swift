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

  func testDashboardIsTheFirstSettingsPane() {
    XCTAssertEqual(SettingsPane.allCases.first, .dashboard)
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
