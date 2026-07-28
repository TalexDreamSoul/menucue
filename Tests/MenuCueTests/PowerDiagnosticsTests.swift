import Foundation
import XCTest

@testable import MenuCue

final class PowerDiagnosticsParserTests: XCTestCase {
  func testWakeStatsParseSinceBootCounts() throws {
    let stats = try PowerDiagnosticsParser.parseWakeStats(
      """
      Sleep Count:25
      Dark Wake Count:22
      User Wake Count:11
      """
    )

    XCTAssertEqual(stats.sleepCount, 25)
    XCTAssertEqual(stats.darkWakeCount, 22)
    XCTAssertEqual(stats.userWakeCount, 11)
  }

  func testWakeStatsRejectMissingFieldsRatherThanReportingZero() {
    XCTAssertThrowsError(try PowerDiagnosticsParser.parseWakeStats("Sleep Count:2"))
  }

  func testWakeEventsPreserveDifferentEventsInTheSameSecond() throws {
    let events = try PowerDiagnosticsParser.parseWakeEvents(
      """
      2026-07-27 17:54:08 +0800 DarkWake             DarkWake from Normal Sleep [CDN] : due to smc.sysState.Wake/ Using AC
      2026-07-27 17:54:08 +0800 Wake                 DarkWake to FullWake from Normal Sleep [CDNVA] : due to Notification Using AC
      """
    )

    XCTAssertEqual(events.count, 2)
    XCTAssertNotEqual(events[0].id, events[1].id)
    XCTAssertEqual(events.map(\.kind), [.darkWake, .wake])
  }

  func testPowerProfilesKeepBatteryAndACValuesSeparate() throws {
    let profiles = try PowerDiagnosticsParser.parsePowerProfiles(
      """
      Battery Power:
       powermode            1
       standby              1
       powernap             0
       womp                 0
       tcpkeepalive         0
      AC Power:
       powermode            2
       standby              1
       powernap             1
       womp                 1
       tcpkeepalive         1
      """
    )

    XCTAssertEqual(profiles.battery?.powerMode, .low)
    XCTAssertEqual(profiles.ac?.powerMode, .high)
    XCTAssertEqual(profiles.battery?.wakeOnNetwork, false)
    XCTAssertEqual(profiles.ac?.wakeOnNetwork, true)
  }

  func testMissingProfileFieldIsUnsupportedNotFalse() throws {
    let profiles = try PowerDiagnosticsParser.parsePowerProfiles(
      """
      AC Power:
       standby              1
      """
    )

    XCTAssertNil(profiles.ac?.powerNap)
    XCTAssertEqual(profiles.ac?.standby, true)
  }

  func testFixedCommandRunnerRejectsOutputWhileReading() {
    let runner = FixedCommandRunner(timeout: 2, maximumOutputBytes: 64)
    let output = String(repeating: "x", count: 2_048)

    XCTAssertThrowsError(try runner.run("/usr/bin/printf", arguments: ["%s", output])) { error in
      guard case FixedCommandError.outputTooLarge = error else {
        return XCTFail("Expected outputTooLarge, got \(error)")
      }
    }
  }

  func testBatteryRegistryParsesSignedTwoComplementCurrent() throws {
    let flow = try PowerDiagnosticsParser.parseBatteryRegistry(
      """
      | |   \"InstantAmperage\" = 18446744073709550616
      | |   \"Voltage\" = 12000
      | |   \"AppleRawMaxCapacity\" = 8000
      """
    )

    XCTAssertEqual(flow.watts, -12, accuracy: 0.001)
    XCTAssertEqual(flow.percentPerHour, -12.5, accuracy: 0.001)
  }
}

final class WakeHistoryStoreTests: XCTestCase {
  private var directory: URL!
  private var fileURL: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent("wake-history.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testMergeDeduplicatesExactEventsButKeepsSameSecondNeighbors() throws {
    let store = WakeHistoryStore(fileURL: fileURL, retentionDays: 30, maxRecords: 100)
    let date = Date(timeIntervalSince1970: 1_000_000)
    let sleep = WakeEvent(timestamp: date, kind: .sleep, reason: "Clamshell Sleep", occurrence: 0)
    let wake = WakeEvent(timestamp: date, kind: .wake, reason: "Lid Open", occurrence: 1)

    try store.merge([sleep, wake, sleep], now: date)
    let loaded = try store.load(now: date)

    XCTAssertEqual(loaded.events, [sleep, wake])
  }

  func testLoadPrunesEventsOlderThanThirtyDays() throws {
    let store = WakeHistoryStore(fileURL: fileURL, retentionDays: 30, maxRecords: 100)
    let now = Date(timeIntervalSince1970: 4_000_000)
    let old = WakeEvent(
      timestamp: now.addingTimeInterval(-31 * 86_400), kind: .sleep, reason: "old", occurrence: 0)
    let recent = WakeEvent(
      timestamp: now.addingTimeInterval(-29 * 86_400), kind: .wake, reason: "recent", occurrence: 0)

    try store.merge([old, recent], now: now)

    XCTAssertEqual(try store.load(now: now).events, [recent])
  }

  func testRecordCeilingKeepsNewestEvents() throws {
    let store = WakeHistoryStore(fileURL: fileURL, retentionDays: 30, maxRecords: 2)
    let now = Date(timeIntervalSince1970: 4_000_000)
    let events = (0..<3).map {
      WakeEvent(timestamp: now.addingTimeInterval(Double($0)), kind: .wake, reason: "e\($0)", occurrence: 0)
    }

    try store.merge(events, now: now)

    XCTAssertEqual(try store.load(now: now).events.map(\.reason), ["e1", "e2"])
  }

  func testClearWatermarkPreventsFullPmsetLogFromRestoringOldEvents() throws {
    let store = WakeHistoryStore(fileURL: fileURL, retentionDays: 30, maxRecords: 100)
    let clearedAt = Date(timeIntervalSince1970: 4_000_000)
    let old = WakeEvent(
      timestamp: clearedAt.addingTimeInterval(-60), kind: .wake, reason: "old", occurrence: 0)
    let fresh = WakeEvent(
      timestamp: clearedAt.addingTimeInterval(60), kind: .wake, reason: "fresh", occurrence: 0)

    try store.merge([old], now: clearedAt)
    try store.clear(now: clearedAt)
    try store.merge([old, fresh], now: fresh.timestamp)

    XCTAssertEqual(try store.load(now: fresh.timestamp).events, [fresh])
  }

  func testDailySummaryCountsKinds() throws {
    let store = WakeHistoryStore(fileURL: fileURL, retentionDays: 30, maxRecords: 100)
    let calendar = Calendar(identifier: .gregorian)
    let day = Date(timeIntervalSince1970: 4_000_000)
    try store.merge(
      [
        WakeEvent(timestamp: day, kind: .sleep, reason: "sleep", occurrence: 0),
        WakeEvent(timestamp: day.addingTimeInterval(1), kind: .darkWake, reason: "dark", occurrence: 0),
        WakeEvent(timestamp: day.addingTimeInterval(2), kind: .wake, reason: "wake", occurrence: 0),
      ],
      now: day,
      calendar: calendar
    )

    let summary = try XCTUnwrap(store.load(now: day, calendar: calendar).dailySummaries.first)
    XCTAssertEqual(summary.sleepCount, 1)
    XCTAssertEqual(summary.darkWakeCount, 1)
    XCTAssertEqual(summary.userWakeCount, 1)
  }
}

private final class PowerDiagnosticsProbeStub: PowerDiagnosticsProbing {
  let batteryHandler: () throws -> BatteryStatus?

  init(batteryHandler: @escaping () throws -> BatteryStatus?) {
    self.batteryHandler = batteryHandler
  }

  func batteryStatus() throws -> BatteryStatus? { try batteryHandler() }
  func wakeStatistics() throws -> WakeStatistics {
    WakeStatistics(sleepCount: 0, darkWakeCount: 0, userWakeCount: 0)
  }
  func wakeEvents() throws -> [WakeEvent] { [] }
  func powerProfiles() throws -> PowerProfiles { PowerProfiles() }
}

final class PowerDiagnosticsServiceLifecycleTests: XCTestCase {
  func testBatterySamplingCoalescesAndRejectsResultAfterRelease() throws {
    let batteryStarted = expectation(description: "battery probe started")
    let unblockBattery = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var callCount = 0
    let probe = PowerDiagnosticsProbeStub {
      lock.lock()
      callCount += 1
      let first = callCount == 1
      lock.unlock()
      if first { batteryStarted.fulfill() }
      _ = unblockBattery.wait(timeout: .now() + 2)
      return BatteryStatus(
        percentage: 80, isCharging: nil, isOnAC: nil,
        timeRemainingMinutes: nil, flow: nil)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = PowerDiagnosticsService(
      probe: probe,
      historyStore: WakeHistoryStore(fileURL: directory.appendingPathComponent("history.json")),
      notificationCenter: NotificationCenter(),
      batteryRefreshInterval: 0.01)

    service.retain()
    wait(for: [batteryStarted], timeout: 1)
    let ticksElapsed = expectation(description: "battery ticks elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ticksElapsed.fulfill() }
    wait(for: [ticksElapsed], timeout: 1)
    lock.lock(); let callsWhileBlocked = callCount; lock.unlock()
    XCTAssertEqual(callsWhileBlocked, 1)

    service.release()
    unblockBattery.signal()
    let settled = expectation(description: "released battery returned")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 1)
    lock.lock(); let callsAfterRelease = callCount; lock.unlock()
    XCTAssertEqual(callsAfterRelease, 1)
    XCTAssertNil(service.battery)
  }
}

private final class ProcessEnergyProbeStub: ProcessEnergyProbing {
  let sampleHandler: (Int) throws -> [ProcessEnergyEntry]

  init(sampleHandler: @escaping (Int) throws -> [ProcessEnergyEntry]) {
    self.sampleHandler = sampleHandler
  }

  func sample(limit: Int) throws -> [ProcessEnergyEntry] {
    try sampleHandler(limit)
  }

  func detail(for identity: ProcessIdentity) throws -> ProcessDetail {
    ProcessDetail(
      identity: identity,
      parentPID: 1,
      userName: "tester",
      cpuPercent: 0,
      memoryPercent: 0,
      nice: 0,
      elapsed: "00:01",
      bundleIdentifier: nil,
      bundleVersion: nil)
  }

  func currentIdentity(pid: Int32) -> ProcessIdentity? {
    .fixture(pid: pid)
  }
}

final class ProcessEnergyServiceLifecycleTests: XCTestCase {
  func testManualRefreshCannotStartAnotherSampleBeforeTheInterval() {
    let firstSample = expectation(description: "first energy sample")
    let secondSample = expectation(description: "second energy sample")
    let lock = NSLock()
    var callCount = 0
    var currentDate = Date(timeIntervalSince1970: 1_000)
    let probe = ProcessEnergyProbeStub { _ in
      lock.lock()
      callCount += 1
      let count = callCount
      lock.unlock()
      if count == 1 { firstSample.fulfill() }
      if count == 2 { secondSample.fulfill() }
      return []
    }
    let service = ProcessEnergyService(
      probe: probe,
      refreshInterval: 1,
      now: { currentDate })

    service.retain()
    wait(for: [firstSample], timeout: 1)
    for _ in 0..<10 { service.refresh() }
    let requestsSettled = expectation(description: "manual requests settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { requestsSettled.fulfill() }
    wait(for: [requestsSettled], timeout: 1)
    lock.lock(); let earlyCalls = callCount; lock.unlock()
    XCTAssertEqual(earlyCalls, 1)

    currentDate = currentDate.addingTimeInterval(1)
    service.refresh()
    wait(for: [secondSample], timeout: 1)
    service.release()
    lock.lock(); let finalCalls = callCount; lock.unlock()
    XCTAssertEqual(finalCalls, 2)
  }

  func testSlowSamplingCoalescesTicksAndRejectsResultAfterRelease() {
    let probeStarted = expectation(description: "energy probe started")
    let unblockProbe = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var callCount = 0
    let entry = ProcessEnergyEntry(
      identity: .fixture(pid: 42),
      name: "Fixture",
      appName: nil,
      energyImpact: 12)
    let probe = ProcessEnergyProbeStub { limit in
      XCTAssertEqual(limit, 12)
      lock.lock()
      callCount += 1
      let isFirstCall = callCount == 1
      lock.unlock()
      if isFirstCall { probeStarted.fulfill() }
      _ = unblockProbe.wait(timeout: .now() + 2)
      return [entry]
    }
    let service = ProcessEnergyService(probe: probe, refreshInterval: 0.01)

    service.retain()
    wait(for: [probeStarted], timeout: 1)
    XCTAssertTrue(service.isRefreshing, "retaining the visible section must sample immediately")

    let ticksElapsed = expectation(description: "refresh ticks elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ticksElapsed.fulfill() }
    wait(for: [ticksElapsed], timeout: 1)
    lock.lock()
    let callsWhileBlocked = callCount
    lock.unlock()
    XCTAssertEqual(callsWhileBlocked, 1, "slow samples must not queue without bound")

    service.release()
    unblockProbe.signal()
    let settled = expectation(description: "released result returned")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 1)

    lock.lock()
    let callsAfterRelease = callCount
    lock.unlock()
    XCTAssertEqual(callsAfterRelease, 1, "hiding the section must stop periodic sampling")
    XCTAssertTrue(service.entries.isEmpty, "a hidden section must not publish a stale sample")
    XCTAssertNil(service.sampledAt)
    XCTAssertFalse(service.isRefreshing)
  }
}

final class PowerDiagnosticsLiveTests: XCTestCase {
  func testSystemProbeReadsCurrentMacWithoutMutatingIt() throws {
    let probe = SystemPowerDiagnosticsProbe()
    let stats = try probe.wakeStatistics()
    XCTAssertGreaterThanOrEqual(stats.sleepCount, 0)
    XCTAssertGreaterThanOrEqual(stats.darkWakeCount, 0)
    XCTAssertGreaterThanOrEqual(stats.userWakeCount, 0)

    let profiles = try probe.powerProfiles()
    XCTAssertNotNil(profiles.ac ?? profiles.battery)
    _ = try probe.batteryStatus()
  }

  func testProcessProbeUsesStableIdentityAndReturnsEnergyRows() throws {
    let probe = SystemProcessEnergyProbe()
    let ownIdentity = try XCTUnwrap(probe.currentIdentity(pid: getpid()))
    XCTAssertEqual(ownIdentity.pid, getpid())
    XCTAssertFalse(ownIdentity.executablePath.isEmpty)

    let rows = try probe.sample(limit: 4)
    XCTAssertFalse(rows.isEmpty)
    XCTAssertLessThanOrEqual(rows.count, 4)
    XCTAssertEqual(rows, rows.sorted { $0.energyImpact > $1.energyImpact })
  }
}

final class ProcessEnergyModelTests: XCTestCase {
  func testProcessControlPolicyRequiresStrongConfirmationAcrossUsersAndSystemPaths() {
    let currentUID: UInt32 = 501
    let normal = ProcessIdentity(
      pid: 1, startTime: 1, ownerUID: currentUID, executablePath: "/Applications/App.app/App")
    let otherUser = ProcessIdentity(
      pid: 2, startTime: 2, ownerUID: 502, executablePath: "/Applications/App.app/App")
    let system = ProcessIdentity(
      pid: 3, startTime: 3, ownerUID: currentUID, executablePath: "/System/Library/CoreServices/Finder.app/Finder")

    XCTAssertFalse(ProcessControlPolicy.requiresStrongConfirmation(for: normal, currentUID: currentUID))
    XCTAssertTrue(ProcessControlPolicy.requiresStrongConfirmation(for: otherUser, currentUID: currentUID))
    XCTAssertTrue(ProcessControlPolicy.requiresStrongConfirmation(for: system, currentUID: currentUID))
  }

  func testTodayDarkWakeCountDoesNotUseTheMostRecentOtherDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = Date(timeIntervalSince1970: 4_000_000)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    var snapshot = PowerDiagnosticsSnapshot()
    snapshot.dailySummaries = [
      WakeDailySummary(
        day: calendar.startOfDay(for: yesterday), sleepCount: 0, darkWakeCount: 7,
        userWakeCount: 0)
    ]

    // `nil`, not `0`. This test's intent — never borrow another day's figure — is
    // unchanged. What changed is that "no record for today" and "today had none" are
    // now distinguishable; they both used to render "0 dark wakes today", and while
    // the log was blowing the size cap every user saw the first dressed as the second.
    XCTAssertNil(snapshot.darkWakeCount(on: today, calendar: calendar))

    var withToday = snapshot
    withToday.dailySummaries.append(
      WakeDailySummary(
        day: calendar.startOfDay(for: today), sleepCount: 0, darkWakeCount: 0,
        userWakeCount: 0))
    XCTAssertEqual(withToday.darkWakeCount(on: today, calendar: calendar), 0)
  }

  func testTopParserUsesPIDAndEnergyButDoesNotTrustTruncatedNameAsIdentity() throws {
    let rows = try ProcessEnergyParser.parseTop(
      """
      PID    COMMAND          POWER
      2188   Orca Helper (Ren 96.9
      405    WindowServer     69.8
      """
    )

    let first = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows.map(\.pid), [2188, 405])
    XCTAssertEqual(first.energyImpact, 96.9, accuracy: 0.001)
    XCTAssertEqual(first.sampledName, "Orca Helper (Ren")
  }

  func testAppAggregationSumsHelpersAndKeepsConcreteMembers() {
    let entries = [
      ProcessEnergyEntry(identity: .fixture(pid: 1), name: "Orca", appName: "Orca", energyImpact: 10),
      ProcessEnergyEntry(
        identity: .fixture(pid: 2), name: "Orca Helper (GPU)", appName: "Orca", energyImpact: 20),
      ProcessEnergyEntry(identity: .fixture(pid: 3), name: "node", appName: nil, energyImpact: 15),
    ]

    let groups = ProcessEnergyAggregator.groups(from: entries)

    XCTAssertEqual(groups.first?.name, "Orca")
    XCTAssertEqual(groups.first?.energyImpact ?? 0, 30, accuracy: 0.001)
    XCTAssertEqual(groups.first?.members.map(\.identity.pid), [1, 2])
    XCTAssertEqual(groups.last?.name, "node")
  }

  func testStableIdentityIncludesStartTimeSoPIDReuseDoesNotCompareEqual() {
    let first = ProcessIdentity(pid: 42, startTime: 100, ownerUID: 501, executablePath: "/bin/a")
    let replacement = ProcessIdentity(pid: 42, startTime: 101, ownerUID: 501, executablePath: "/bin/a")

    XCTAssertNotEqual(first, replacement)
  }
}
