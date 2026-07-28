import Foundation
import XCTest

@testable import MenuCue

/// Fixtures are real `pmset` output captured from a Mac with several days of uptime,
/// scrubbed of hostnames, account names and account numbers.
private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
    .appendingPathComponent(name)
  return try String(contentsOf: url, encoding: .utf8)
}

final class WakeEventParsingTests: XCTestCase {
  func testScheduledWakesAreNeverReportedAsWakesThatHappened() throws {
    // These lines are written at *sleep* time and list wakes planned for the future.
    // They used to match `Wake\s+` because pmset pads its domain column, so roughly a
    // third of the wake list was made of events that had not occurred.
    let text = try fixture("pmset-wake-requests.txt")
    XCTAssertFalse(text.isEmpty, "fixture is empty")
    XCTAssertTrue(text.contains("Wake Requests"))

    let events = try PowerDiagnosticsParser.parseWakeEvents(text)
    XCTAssertTrue(events.isEmpty, "a Wake Requests line was parsed as a wake: \(events)")
  }

  func testRealWakeLinesStillParse() throws {
    let text = try fixture("pmset-wake-events.txt")
    let events = try PowerDiagnosticsParser.parseWakeEvents(text)
    XCTAssertFalse(events.isEmpty, "no wake events parsed from real output")

    // The fixture was captured with a grep that itself hit the padding bug, so it
    // contains Wake Requests lines too. None of them may become an event.
    let requestLines = text.split(whereSeparator: \.isNewline)
      .filter { $0.contains("Wake Requests") }.count
    let eventLines = text.split(whereSeparator: \.isNewline)
      .filter { PowerDiagnosticsParser.isInterestingLogLine(String($0)) }.count
    XCTAssertGreaterThan(requestLines, 0, "fixture should exercise the padding bug")
    XCTAssertLessThanOrEqual(events.count, eventLines)

    for event in events {
      XCTAssertFalse(
        event.reason.contains("process="),
        "a scheduled-wake blob leaked into a reason: \(event.reason)")
      XCTAssertLessThan(event.reason.count, 200, "reason looks like a whole line")
    }
  }

  func testTheStreamingFilterKeepsOnlyTheDomainsWeRead() throws {
    // What the filter must reject is the bulk of the file: on the captured machine
    // 98.6% of 23.9 MB was Assertions.
    let assertion =
      "2026-07-28 00:47:17 -0700 Assertions          \tPID 95031(rcd) Summary UserIsActive"
    let wake =
      "2026-07-26 08:17:36 -0700 Wake                \tWake from Deep Idle : due to lid"
    let sleep =
      "2026-07-26 08:15:28 -0700 Sleep               \tEntering Sleep state due to 'Idle Sleep'"
    let request =
      "2026-07-26 08:15:28 -0700 Wake Requests       \t[process=dasd request=SleepService]"

    XCTAssertFalse(PowerDiagnosticsParser.isInterestingLogLine(assertion))
    XCTAssertTrue(PowerDiagnosticsParser.isInterestingLogLine(wake))
    XCTAssertTrue(PowerDiagnosticsParser.isInterestingLogLine(sleep))
    // Kept by the cheap filter — the regex is what rejects it, so the two stay in step
    // and a filter change cannot silently start dropping real wakes.
    XCTAssertTrue(PowerDiagnosticsParser.isInterestingLogLine(request))
    XCTAssertTrue(try PowerDiagnosticsParser.parseWakeEvents(request).isEmpty)

    XCTAssertFalse(PowerDiagnosticsParser.isInterestingLogLine(""))
    XCTAssertFalse(PowerDiagnosticsParser.isInterestingLogLine("short"))
  }
}

final class LineFilteringCaptureTests: XCTestCase {
  private func capture(_ text: String, keep: @escaping @Sendable (String) -> Bool)
    -> (lines: [String], bytesSeen: Int, droppedOversizedLine: Bool)
  {
    let pipe = Pipe()
    // The capture filters bytes; these tests express intent in terms of text.
    let capture = LineFilteringCapture { keep(String(decoding: $0, as: UTF8.self)) }
    DispatchQueue.global().async {
      pipe.fileHandleForWriting.write(Data(text.utf8))
      pipe.fileHandleForWriting.closeFile()
    }
    capture.read(from: pipe.fileHandleForReading)
    return capture.snapshot()
  }

  func testOnlyMatchingLinesAreRetained() {
    let text = (0..<1_000).map { "line \($0) \($0 % 100 == 0 ? "KEEP" : "DROP")" }
      .joined(separator: "\n")
    let result = capture(text) { $0.contains("KEEP") }
    XCTAssertEqual(result.lines.count, 10)
    XCTAssertGreaterThan(result.bytesSeen, 10_000, "the whole stream is still read")
  }

  func testALineWithoutATrailingNewlineIsStillSeen() {
    let result = capture("first KEEP\nsecond KEEP") { $0.contains("KEEP") }
    XCTAssertEqual(result.lines, ["first KEEP", "second KEEP"])
  }

  func testLinesSplitAcrossChunkBoundariesReassemble() {
    // 256 KB read size; a line that straddles it must not be torn in half.
    let filler = String(repeating: "x", count: 300 * 1_024)
    let result = capture("\(filler) KEEP\nshort KEEP") { $0.contains("KEEP") }
    XCTAssertEqual(result.lines.count, 2)
    XCTAssertEqual(result.lines[0].count, filler.count + 5)
  }

  func testAPathologicalLineIsDroppedRatherThanGrowingWithoutBound() {
    let capture = LineFilteringCapture(maximumLineBytes: 4_096) { _ in true }
    let pipe = Pipe()
    DispatchQueue.global().async {
      pipe.fileHandleForWriting.write(Data(String(repeating: "y", count: 100_000).utf8))
      pipe.fileHandleForWriting.closeFile()
    }
    capture.read(from: pipe.fileHandleForReading)
    XCTAssertTrue(capture.snapshot().droppedOversizedLine)
  }
}

final class ScheduledWakeParsingTests: XCTestCase {
  func testRealWakeRequestLinesParse() throws {
    let scheduled = PowerAttributionParser.parseScheduledWakes(
      try fixture("pmset-wake-requests.txt"))
    XCTAssertFalse(scheduled.isEmpty, "no scheduled wakes parsed from real output")

    // One line holds many requests; exactly one of them is starred.
    let byLine = Dictionary(grouping: scheduled, by: \.loggedAt)
    for (loggedAt, group) in byLine {
      let winners = group.filter(\.isWinning)
      XCTAssertEqual(winners.count, 1, "expected one winning request at \(loggedAt)")
      XCTAssertGreaterThan(group.count, 1, "a real line lists several requests")
    }

    for wake in scheduled {
      XCTAssertFalse(wake.process.isEmpty)
      XCTAssertGreaterThan(wake.wakeAt, wake.loggedAt, "a scheduled wake is in the future")
    }
    XCTAssertTrue(
      scheduled.contains { $0.process == "dasd" || $0.process == "mDNSResponder" },
      "expected the usual schedulers: \(Set(scheduled.map(\.process)))")
  }

  func testInfoWithBracketsDoesNotBreakTheSplit() {
    let line = """
      2026-07-27 17:51:13 -0700 Wake Requests       \t[*process=dasd request=SleepService \
      deltaSecs=946 wakeAt=2026-07-27 18:06:58 info="thing [with] brackets"] \
      [process=powerd request=TCPKATurnOff deltaSecs=315437 wakeAt=2026-07-31 09:28:30]
      """
    let scheduled = PowerAttributionParser.parseScheduledWakes(line)
    XCTAssertEqual(scheduled.count, 2)
    XCTAssertEqual(scheduled[0].info, "thing [with] brackets")
    XCTAssertTrue(scheduled[0].isWinning)
    XCTAssertFalse(scheduled[1].isWinning)
  }
}

final class WakeAttributionTests: XCTestCase {
  private func scheduled(at wakeAt: Date, process: String, winning: Bool) -> ScheduledWake {
    ScheduledWake(
      loggedAt: wakeAt.addingTimeInterval(-900), wakeAt: wakeAt, process: process,
      request: "SleepService", info: "com.apple.dasd:0:com.apple.chronod.checkForUpdates",
      isWinning: winning)
  }

  func testAWakeNearItsScheduledTimeIsAttributed() {
    let at = Date()
    let cause = PowerAttributionParser.attribute(
      wakeAt: at, interruptToken: "rtc/SleepService",
      scheduled: [scheduled(at: at.addingTimeInterval(3), process: "dasd", winning: true)])

    guard case let .process(name, _, detail) = cause else {
      return XCTFail("expected process attribution, got \(cause)")
    }
    XCTAssertEqual(name, "dasd")
    XCTAssertEqual(detail, "check for updates")
  }

  func testAWakeOutsideToleranceIsNotGuessedAt() {
    let at = Date()
    let cause = PowerAttributionParser.attribute(
      wakeAt: at, interruptToken: "lid",
      scheduled: [scheduled(at: at.addingTimeInterval(3_600), process: "dasd", winning: true)])

    // Falls back to the interrupt rather than blaming the nearest process.
    guard case let .interrupt(token, plain) = cause else {
      return XCTFail("expected interrupt, got \(cause)")
    }
    XCTAssertEqual(token, "lid")
    XCTAssertEqual(plain, "Opening the lid")
  }

  func testOnlyTheWinningRequestCanBeTheCause() {
    let at = Date()
    let cause = PowerAttributionParser.attribute(
      wakeAt: at, interruptToken: "rtc",
      scheduled: [scheduled(at: at, process: "mDNSResponder", winning: false)])
    // A non-winning request was never going to fire first.
    if case .process = cause { XCTFail("attributed to a request that would not fire") }
  }

  func testAnUnknownTokenShowsWhatWasRecorded() {
    let cause = WakeReasonDictionary.cause(forInterrupt: "XYZ.Unheard.Of")
    guard case let .interrupt(token, plain) = cause else { return XCTFail("expected interrupt") }
    XCTAssertEqual(token, "XYZ.Unheard.Of")
    XCTAssertTrue(plain.contains("XYZ.Unheard.Of"), "an unknown token must not be hidden")
  }

  func testEmptyTokenIsUnknownRatherThanInvented() {
    XCTAssertEqual(WakeReasonDictionary.cause(forInterrupt: "   "), .unknown)
  }

  func testRealInterruptTokensMapToPlainLanguage() {
    // Captured from this Mac's own log.
    XCTAssertEqual(
      WakeReasonDictionary.plainLanguage(for: "smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty"),
      "Opening the lid")
    XCTAssertEqual(
      WakeReasonDictionary.plainLanguage(for: "NUB.SPMI0Sw3IRQ nub-spmi0.0x02 rtc/SleepService"),
      "A scheduled background task")
  }
}

final class SleepAssertionParsingTests: XCTestCase {
  func testRealAssertionsParse() throws {
    let assertions = PowerAttributionParser.parseAssertions(try fixture("pmset-assertions.txt"))
    XCTAssertFalse(assertions.isEmpty, "no assertions parsed from real output")

    for assertion in assertions {
      XCTAssertGreaterThan(assertion.pid, 0)
      XCTAssertFalse(assertion.process.isEmpty)
      XCTAssertFalse(assertion.type.isEmpty)
    }
    XCTAssertTrue(
      assertions.contains { $0.preventsSystemSleep },
      "the captured machine had processes preventing sleep")
  }

  func testTheLongHeldAssertionOnTheCapturedMachineIsFound() throws {
    // UURemote had held PreventUserIdleSystemSleep for 89 hours — exactly the kind of
    // fact this pane exists to surface.
    let assertions = PowerAttributionParser.parseAssertions(try fixture("pmset-assertions.txt"))
    guard let longest = assertions.max(by: { $0.heldSeconds < $1.heldSeconds }) else {
      return XCTFail("no assertions")
    }
    XCTAssertGreaterThan(longest.heldSeconds, 3_600, "expected a multi-hour holder")
    XCTAssertTrue(longest.heldDescription.contains("h"))
  }

  func testLocalizedContinuationIsPreferred() {
    let text = """
      Listed by owning process:
         pid 49842(caffeinate): [0x0004a3ff0001862b] 00:01:29 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
      \tDetails: caffeinate asserting for 300 secs
      \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
      \tTimeout will fire in 210 secs Action=TimeoutActionRelease
      """
    let assertions = PowerAttributionParser.parseAssertions(text)
    XCTAssertEqual(assertions.count, 1)
    XCTAssertEqual(assertions[0].pid, 49842)
    XCTAssertEqual(assertions[0].process, "caffeinate")
    XCTAssertEqual(assertions[0].localized, "THE CAFFEINATE TOOL IS PREVENTING SLEEP.")
    XCTAssertEqual(assertions[0].heldSeconds, 89)
    XCTAssertTrue(assertions[0].preventsSystemSleep)
  }

  func testHoursBeyondADayParse() {
    // 89:44:59 is not a time of day.
    XCTAssertEqual(PowerAttributionParser.parseDuration("89:44:59"), 89 * 3_600 + 44 * 60 + 59)
    XCTAssertEqual(PowerAttributionParser.parseDuration("nonsense"), 0)
  }
}

final class ReadableInfoTests: XCTestCase {
  func testCamelCaseLeafBecomesWords() {
    XCTAssertEqual(
      PowerAttributionParser.readableInfo(
        "com.apple.dasd:0:com.apple.chronod.nextScheduledTimelineRefresh"),
      "next scheduled timeline refresh")
  }

  func testAnAllLowercaseLeafIsStillJustTheLeaf() {
    // This printed the whole dotted string until the leaf was returned rather than
    // the segment after the last colon.
    XCTAssertEqual(
      PowerAttributionParser.readableInfo("com.apple.searchd.heartbeat"), "heartbeat")
    XCTAssertEqual(
      PowerAttributionParser.readableInfo("com.apple.dasd:0:com.apple.searchd.heartbeat"),
      "heartbeat")
  }

  func testPlainTextIsLeftAlone() {
    XCTAssertEqual(PowerAttributionParser.readableInfo("upkeep wake"), "upkeep wake")
  }
}

final class BatteryRegistryParsingTests: XCTestCase {
  func testTheTopLevelKeyIsReadNotTheNestedOne() throws {
    // ioreg prints nested dictionaries inline, so BatteryData is a single enormous
    // line carrying its own "Voltage"=… tens of lines before the real top-level key.
    let text = try fixture("ioreg-battery.txt")
    let nestedLine = text.split(whereSeparator: \.isNewline)
      .first { $0.contains("\"BatteryData\"") }
    XCTAssertNotNil(nestedLine, "fixture should contain the nested blob")
    XCTAssertTrue(nestedLine!.contains("\"Voltage\"="), "the trap this test exists for")

    let flow = try PowerDiagnosticsParser.parseBatteryRegistry(text)
    XCTAssertTrue(flow.watts.isFinite)
    XCTAssertTrue(flow.percentPerHour.isFinite)
  }

  func testANegativeAmperageStaysNegative() throws {
    let text = """
          "AppleRawMaxCapacity" = 8000
          "InstantAmperage" = -1500
          "Voltage" = 12000
      """
    let flow = try PowerDiagnosticsParser.parseBatteryRegistry(text)
    // Discharging must not read as charging.
    XCTAssertLessThan(flow.watts, 0)
    XCTAssertLessThan(flow.percentPerHour, 0)
  }

  func testUnsignedTwosComplementIsStillNegative() throws {
    // Some Macs print the same value as an unsigned 64-bit literal.
    let text = """
          "AppleRawMaxCapacity" = 8000
          "InstantAmperage" = 18446744073709550116
          "Voltage" = 12000
      """
    let flow = try PowerDiagnosticsParser.parseBatteryRegistry(text)
    XCTAssertLessThan(flow.watts, 0)
  }

  func testANestedKeyAloneIsNotEnough() {
    // Only the inline blob, no top-level property: better to report the field missing
    // than to read a value from inside another dictionary.
    let text = #"  "BatteryData" = {"Voltage"=12345,"Qmax"=(1,2)}"#
    XCTAssertThrowsError(try PowerDiagnosticsParser.parseBatteryRegistry(text))
  }
}

@MainActor
final class PowerMonitoringOptInTests: XCTestCase {
  private func store() -> SettingsStore {
    let suite = "PowerMonitoringOptInTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return SettingsStore(defaults: defaults)
  }

  func testBackgroundMonitoringIsOffUntilTheFeatureIsOpened() {
    // A user who never looks at power must never have pmset run for them.
    XCTAssertFalse(store().load().powerMonitoringEnabled)
  }

  func testOpeningTheFeatureTurnsItOnAndItPersists() {
    let settingsStore = store()
        var settings = settingsStore.load()
    XCTAssertFalse(settings.powerMonitoringEnabled)

    settings.powerMonitoringEnabled = true
    settingsStore.save(settings)

    // Survives relaunch, which is the point: the history has to keep accruing.
    XCTAssertTrue(settingsStore.load().powerMonitoringEnabled)
  }
}
