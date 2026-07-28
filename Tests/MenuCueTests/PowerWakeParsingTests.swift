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
