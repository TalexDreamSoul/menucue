import Combine
import Foundation
import XCTest

@testable import MenuCue

private struct ProcessHealthProbeStub: ProcessHealthProbing {
  let result: ProcessHealthSnapshot

  func scan() throws -> ProcessHealthSnapshot { result }
}

final class ProcessHealthTests: XCTestCase {
  func testParserCollapsesThreadRowsAndRanksProcessesDeterministically() throws {
    let scannedAt = Date(timeIntervalSince1970: 1_760_000_000)
    let output = """
      7 1 S 72.5 1.3 /Applications/Editor Pro.app/Contents/MacOS/Editor Pro --project /tmp/work
      7 1 S 72.5 1.3 /Applications/Editor Pro.app/Contents/MacOS/Editor Pro --project /tmp/work
      7 1 S 72.5 1.3 /Applications/Editor Pro.app/Contents/MacOS/Editor Pro --project /tmp/work
      42 1 Z+ 72.5 0.1 /usr/local/bin/defunct worker --queue nightly
      42 1 Z+ 72.5 0.1 /usr/local/bin/defunct worker --queue nightly
      99 1 R 15.0 2.4 /usr/bin/render job --frames 1 2 3
      99 1 R 15.0 2.4 /usr/bin/render job --frames 1 2 3
      99 1 R 15.0 2.4 /usr/bin/render job --frames 1 2 3
      99 1 R 15.0 2.4 /usr/bin/render job --frames 1 2 3
      120 1 S 5.0 0.8 /usr/bin/background worker --idle
      120 1 S 5.0 0.8 /usr/bin/background worker --idle
      """

    let snapshot = try ProcessHealthParser.parsePS(output, scannedAt: scannedAt)

    XCTAssertEqual(snapshot.scannedAt, scannedAt)
    XCTAssertEqual(snapshot.processes.count, 4, "thread rows must not become separate processes")
    XCTAssertEqual(snapshot.totalThreads, 11)

    let editor = try XCTUnwrap(snapshot.processes.first { $0.pid == 7 })
    XCTAssertEqual(editor.threadCount, 3)
    XCTAssertEqual(
      editor.command,
      "/Applications/Editor Pro.app/Contents/MacOS/Editor Pro --project /tmp/work")
    XCTAssertEqual(snapshot.zombies.map(\.pid), [42], "a Z-prefixed state must remain visible as a zombie")

    XCTAssertEqual(snapshot.busiestProcesses.map(\.pid), [7, 42, 99, 120])
    XCTAssertEqual(snapshot.mostThreadedProcesses.map(\.pid), [99, 7, 42, 120])
  }

  func testAnalyzePublishesTheInjectedProbeResult() {
    let expected = ProcessHealthSnapshot(
      processes: [
        ProcessHealthProcess(
          pid: 501,
          parentPID: 1,
          state: "R",
          cpuPercent: 63.2,
          memoryPercent: 1.25,
          command: "/usr/local/bin/analysis worker --once",
          threadCount: 2)
      ],
      totalThreads: 2,
      scannedAt: Date(timeIntervalSince1970: 1_760_000_100))
    let service = ProcessHealthService(probe: ProcessHealthProbeStub(result: expected))
    let published = expectation(description: "manual process-health scan publishes its snapshot")
    var cancellables = Set<AnyCancellable>()

    service.$snapshot
      .compactMap { $0 }
      .sink { snapshot in
        guard snapshot == expected else { return }
        published.fulfill()
      }
      .store(in: &cancellables)

    service.analyze()

    wait(for: [published], timeout: 1)
    XCTAssertEqual(service.snapshot, expected)
  }
}
