import Foundation
import XCTest

@testable import MenuCue

private func entry(_ name: String, _ impact: Double, pid: Int32 = 1) -> ProcessEnergyEntry {
  ProcessEnergyEntry(
    identity: .fixture(pid: pid), name: name, appName: nil, energyImpact: impact)
}

final class ProcessEnergyHistoryTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_760_000_000)

  func testPersistenceIsWhatTheHistoryIsFor() {
    var history = ProcessEnergyHistory()
    // A daemon that is always there but never hot, versus a brief violent spike.
    for step in 0..<10 {
      var sample = [entry("backupd", 2)]
      if step == 5 { sample.append(entry("compiler", 400, pid: 2)) }
      history.record(sample, at: start.addingTimeInterval(Double(step) * 300))
    }

    // By energy the spike wins, which is correct and is a different question.
    XCTAssertEqual(history.topByEnergy(limit: 1).first?.name, "compiler")
    // By persistence the daemon wins — this is "what keeps running".
    XCTAssertEqual(history.topByPersistence(limit: 1).first?.name, "backupd")

    let daemon = history.records["backupd"]!
    XCTAssertEqual(daemon.sampleCount, 10)
    XCTAssertEqual(daemon.presence(inWindowOf: history.totalSamples), 1, accuracy: 0.001)

    // Presence is measured from when a process first appeared, not from when the
    // history began. The compiler showed up in sample 6 of 10, so its own window is
    // five samples and it was in one of them — 20%, not the 10% you get by dividing
    // through the whole history. Measuring against the whole window would mean a
    // process launched a minute ago could never read above a few percent, and after
    // a trim drops old records while the sample counter keeps climbing, every figure
    // would drift downward forever.
    XCTAssertEqual(
      history.records["compiler"]!.presence(inWindowOf: history.totalSamples), 0.2,
      accuracy: 0.001)
  }

  func testAveragesAndPeaksAreBothKept() {
    var history = ProcessEnergyHistory()
    history.record([entry("node", 10)], at: start)
    history.record([entry("node", 90)], at: start.addingTimeInterval(60))

    let record = history.records["node"]!
    XCTAssertEqual(record.averageImpact, 50, accuracy: 0.001)
    // A brief spike must stay visible behind the average that flattens it.
    XCTAssertEqual(record.peakImpact, 90)
    XCTAssertEqual(record.totalImpact, 100)
  }

  func testPruningKeepsThePersistentOnesNotTheLoudest() {
    var history = ProcessEnergyHistory()
    history.maximumRecords = 2
    // Two steady processes and one enormous one-off.
    for step in 0..<5 {
      history.record(
        [entry("steadyA", 1, pid: 1), entry("steadyB", 1, pid: 2)],
        at: start.addingTimeInterval(Double(step) * 60))
    }
    history.record([entry("spike", 9_999, pid: 3)], at: start.addingTimeInterval(600))

    XCTAssertEqual(history.records.count, 2)
    XCTAssertNotNil(history.records["steadyA"])
    XCTAssertNotNil(history.records["steadyB"])
    XCTAssertNil(history.records["spike"], "a one-off displaced something that keeps running")
  }

  func testTrimmingDropsWhatFellOutOfTheWindow() {
    var history = ProcessEnergyHistory()
    history.record([entry("old", 5)], at: start)
    history.record([entry("recent", 5, pid: 2)], at: start.addingTimeInterval(7_200))

    history.trim(before: start.addingTimeInterval(3_600))
    XCTAssertNil(history.records["old"])
    XCTAssertNotNil(history.records["recent"])
  }

  func testAnEmptySampleIsNotCountedAsAWindow() {
    var history = ProcessEnergyHistory()
    history.record([], at: start)
    // Counting it would dilute every presence figure with samples that saw nothing.
    XCTAssertEqual(history.totalSamples, 0)
    XCTAssertNil(history.windowStart)
  }

  func testPresenceIsSafeWithNoSamples() {
    let record = ProcessEnergyRecord(
      name: "x", totalImpact: 0, sampleCount: 0, firstSeen: start, lastSeen: start,
      peakImpact: 0)
    XCTAssertEqual(record.presence(inWindowOf: 0), 0)
    XCTAssertEqual(record.averageImpact, 0)
  }
}

final class ProcessEnergyHistoryStoreTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_760_000_000)

  private func store() -> (ProcessEnergyHistoryStore, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("energy-\(UUID().uuidString).json")
    return (ProcessEnergyHistoryStore(fileURL: url), url)
  }

  func testHistorySurvivesRelaunch() throws {
    let (persisted, url) = store()
    defer { try? FileManager.default.removeItem(at: url) }

    var history = ProcessEnergyHistory()
    history.record([entry("bun", 12)], at: start)
    try persisted.save(history)

    // A different instance, as after a relaunch.
    let reopened = ProcessEnergyHistoryStore(fileURL: url)
    let restored = try reopened.load(now: start.addingTimeInterval(60))
    XCTAssertEqual(restored.records["bun"]?.totalImpact, 12)
    XCTAssertEqual(restored.totalSamples, 1)
  }

  func testLoadingDropsRecordsOlderThanRetention() throws {
    let (persisted, url) = store()
    defer { try? FileManager.default.removeItem(at: url) }

    var history = ProcessEnergyHistory()
    history.record([entry("ancient", 3)], at: start)
    try persisted.save(history)

    // Four days later, against a 72-hour window.
    let restored = try persisted.load(now: start.addingTimeInterval(4 * 86_400))
    XCTAssertTrue(restored.records.isEmpty)
  }

  func testAnUnchangedSaveDoesNotRewrite() throws {
    let (persisted, url) = store()
    defer { try? FileManager.default.removeItem(at: url) }

    var history = ProcessEnergyHistory()
    history.record([entry("node", 1)], at: start)
    try persisted.save(history)
    XCTAssertEqual(persisted.writeCount, 1)

    try persisted.save(history)
    XCTAssertEqual(persisted.writeCount, 1, "an unchanged save rewrote the file")

    history.record([entry("node", 2)], at: start.addingTimeInterval(60))
    try persisted.save(history)
    XCTAssertEqual(persisted.writeCount, 2, "a real change was not written")
  }

  func testAnUnknownVersionIsRefused() throws {
    let (persisted, url) = store()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"version":99,"history":{"records":{},"totalSamples":0}}"#.utf8).write(to: url)
    XCTAssertThrowsError(try persisted.load())
  }

  func testMissingFileIsAnEmptyHistoryNotAnError() throws {
    let (persisted, url) = store()
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertTrue(try persisted.load().records.isEmpty)
  }
}

extension ProcessEnergyHistoryTests {
  func testAMultiProcessAppCountsAsOneAppearance() {
    var history = ProcessEnergyHistory()
    // What a real `top` sample looks like: one browser, seven helpers.
    let sample = (0..<7).map { entry("node", 10, pid: Int32($0 + 1)) }
    history.record(sample, at: start)

    let record = history.records["node"]!
    XCTAssertEqual(history.totalSamples, 1)
    XCTAssertEqual(record.sampleCount, 1, "each process was counted as its own appearance")
    // Impact still sums across the processes — that part was right.
    XCTAssertEqual(record.totalImpact, 70)
    XCTAssertEqual(record.peakImpact, 70, "peak is the app's total in one sample")
    XCTAssertEqual(record.presence(inWindowOf: history.totalSamples), 1, accuracy: 0.001)
  }

  func testASingleProcessDaemonCanOutrankAMultiProcessApp() {
    var history = ProcessEnergyHistory()
    // The daemon is in every sample; the browser only in the last one.
    for step in 0..<5 {
      var sample = [entry("backupd", 1, pid: 99)]
      if step == 4 {
        sample += (0..<7).map { entry("Chrome", 50, pid: Int32($0 + 1)) }
      }
      history.record(sample, at: start.addingTimeInterval(Double(step) * 60))
    }

    XCTAssertEqual(
      history.topByPersistence(limit: 1).first?.name, "backupd",
      "a burst of helper processes outranked something that ran the whole window")
    XCTAssertEqual(history.records["Chrome"]?.sampleCount, 1)
  }

  func testPresenceNeverExceedsTheWindow() {
    var history = ProcessEnergyHistory()
    history.record((0..<20).map { entry("node", 1, pid: Int32($0 + 1)) }, at: start)
    let record = history.records["node"]!
    XCTAssertLessThanOrEqual(record.presence(inWindowOf: history.totalSamples), 1)
  }
}

extension ProcessEnergyHistoryTests {
  func testALateArrivalThatNeverMissesReadsAsAlwaysPresent() {
    var history = ProcessEnergyHistory()
    for step in 0..<10 {
      var sample = [entry("old", 1, pid: 1)]
      // Joins halfway and is in every sample from then on.
      if step >= 5 { sample.append(entry("new", 1, pid: 2)) }
      history.record(sample, at: start.addingTimeInterval(Double(step) * 60))
    }

    XCTAssertEqual(
      history.records["new"]!.presence(inWindowOf: history.totalSamples), 1, accuracy: 0.001,
      "a process present in every sample since it started should read as always present")
  }

  func testPresenceDoesNotDriftAfterATrim() {
    var history = ProcessEnergyHistory()
    // A long-gone process, then a steady one that starts later.
    history.record([entry("gone", 1, pid: 1)], at: start)
    for step in 1...5 {
      history.record([entry("steady", 1, pid: 2)], at: start.addingTimeInterval(Double(step) * 3_600))
    }
    history.trim(before: start.addingTimeInterval(1_800))

    XCTAssertNil(history.records["gone"])
    // totalSamples still counts the trimmed sample; the per-record baseline is what
    // keeps this honest.
    XCTAssertEqual(
      history.records["steady"]!.presence(inWindowOf: history.totalSamples), 1, accuracy: 0.001)
  }
}
