import Darwin
import Foundation
import IOKit.ps

struct BatteryStatus: Equatable {
  let percentage: Int
  let isCharging: Bool?
  let isOnAC: Bool?
  let timeRemainingMinutes: Int?
  let flow: BatteryFlow?
}

struct CommandOutput {
  let standardOutput: String
  let standardError: String
}

enum FixedCommandError: LocalizedError {
  case missingExecutable(String)
  case timedOut(String)
  case failed(String)
  case outputTooLarge(String)

  var errorDescription: String? {
    switch self {
    case .missingExecutable(let path): return "Required system tool is unavailable: \(path)"
    case .timedOut(let name): return "\(name) timed out."
    case .failed(let message): return message
    case .outputTooLarge(let name): return "\(name) returned too much data."
    }
  }
}

private final class BoundedPipeCapture: @unchecked Sendable {
  private let maximumBytes: Int
  private let lock = NSLock()
  private var storage = Data()
  private(set) var overflowed = false

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func read(from handle: FileHandle) {
    while true {
      let chunk = handle.readData(ofLength: 64 * 1_024)
      guard !chunk.isEmpty else { return }
      lock.lock()
      if storage.count + chunk.count > maximumBytes {
        overflowed = true
        lock.unlock()
        return
      }
      storage.append(chunk)
      lock.unlock()
    }
  }

  func snapshot() -> (data: Data, overflowed: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (storage, overflowed)
  }
}

/// Keeps only the lines a predicate accepts, so a command whose output is far larger
/// than the interesting part never has to fit in memory.
///
/// `pmset -g log` is 23.9 MB on a Mac with a few days of uptime, of which 98.6% is the
/// `Assertions` domain this app does not read from the log at all. Buffering the whole
/// thing is what made the wake list permanently empty: it blew the cap, the command was
/// killed, and the pane showed a raw error instead of any history.
final class LineFilteringCapture: @unchecked Sendable {
  /// Applied to the raw bytes. Deliberately not `(String) -> Bool`: building a `String`
  /// for all 105,000 lines to discard 98.6% of them cost 31 s on top of `pmset`'s own
  /// 5.4 s. Only lines that pass are materialized.
  private let keepLine: @Sendable (Data.SubSequence) -> Bool
  /// Guards against a single pathological line growing without bound.
  private let maximumLineBytes: Int
  private let lock = NSLock()
  private var pending = Data()
  private var kept: [String] = []
  private(set) var droppedOversizedLine = false
  private var totalBytesSeen = 0

  init(
    maximumLineBytes: Int = 1_024 * 1_024,
    keepLine: @escaping @Sendable (Data.SubSequence) -> Bool
  ) {
    self.maximumLineBytes = maximumLineBytes
    self.keepLine = keepLine
  }

  func read(from handle: FileHandle) {
    while true {
      let chunk = handle.readData(ofLength: 256 * 1_024)
      guard !chunk.isEmpty else { break }
      lock.lock()
      totalBytesSeen += chunk.count
      pending.append(chunk)
      consumeCompleteLines()
      lock.unlock()
    }
    lock.lock()
    // A trailing line with no newline is still a line.
    if !pending.isEmpty {
      offer(pending[pending.startIndex..<pending.endIndex])
      pending.removeAll(keepingCapacity: false)
    }
    lock.unlock()
  }

  /// Called with the lock held.
  ///
  /// Splits the whole buffer once and keeps only the trailing partial line. Removing
  /// each line from the front instead is O(n) per line, which turned a 24 MB stream
  /// into quadratic work — measured at over 12 s against `pmset`'s own 5.4 s.
  private func consumeCompleteLines() {
    let newline = UInt8(ascii: "\n")
    guard let lastNewline = pending.lastIndex(of: newline) else {
      if pending.count > maximumLineBytes {
        // Never seen in practice; dropping beats growing without bound.
        droppedOversizedLine = true
        pending.removeAll(keepingCapacity: false)
      }
      return
    }

    var lineStart = pending.startIndex
    var index = pending.startIndex
    while index < lastNewline {
      if pending[index] == newline {
        offer(pending[lineStart..<index])
        lineStart = pending.index(after: index)
      }
      index = pending.index(after: index)
    }
    offer(pending[lineStart..<lastNewline])
    pending = Data(pending[pending.index(after: lastNewline)...])
  }

  /// Called with the lock held.
  private func offer(_ line: Data.SubSequence) {
    guard !line.isEmpty, keepLine(line) else { return }
    kept.append(String(decoding: line, as: UTF8.self))
  }

  func snapshot() -> (lines: [String], bytesSeen: Int, droppedOversizedLine: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (kept, totalBytesSeen, droppedOversizedLine)
  }
}

/// Result of a streamed command: the lines that survived the filter, plus how much was
/// read to find them.
struct StreamedCommandOutput {
  let lines: [String]
  let bytesRead: Int
  /// True when a line was too long to hold; the result is usable but incomplete.
  let isPartial: Bool
}

struct FixedCommandRunner {
  var timeout: TimeInterval = 12
  var maximumOutputBytes = 16 * 1_024 * 1_024

  func run(_ executablePath: String, arguments: [String]) throws -> CommandOutput {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw FixedCommandError.missingExecutable(executablePath)
    }

    let process = Process()
    let output = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, fixed in fixed }
    process.standardOutput = output
    process.standardError = errorPipe

    let group = DispatchGroup()
    let outputCapture = BoundedPipeCapture(maximumBytes: maximumOutputBytes)
    let errorCapture = BoundedPipeCapture(maximumBytes: maximumOutputBytes)
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      outputCapture.read(from: output.fileHandleForReading)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      errorCapture.read(from: errorPipe.fileHandleForReading)
      group.leave()
    }

    do {
      try process.run()
    } catch {
      output.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      group.wait()
      throw error
    }

    let deadline = DispatchTime.now() + timeout
    var timedOut = false
    var outputTooLarge = false
    while process.isRunning {
      if outputCapture.snapshot().overflowed || errorCapture.snapshot().overflowed {
        outputTooLarge = true
        break
      }
      if DispatchTime.now() >= deadline {
        timedOut = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      let terminationDeadline = DispatchTime.now() + 1
      while process.isRunning, DispatchTime.now() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
    group.wait()

    let capturedOutput = outputCapture.snapshot()
    let capturedError = errorCapture.snapshot()
    let name = URL(fileURLWithPath: executablePath).lastPathComponent
    if timedOut { throw FixedCommandError.timedOut(name) }
    if outputTooLarge || capturedOutput.overflowed || capturedError.overflowed {
      throw FixedCommandError.outputTooLarge(name)
    }
    let stdout = String(decoding: capturedOutput.data, as: UTF8.self)
    let stderr = String(decoding: capturedError.data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw FixedCommandError.failed(
        detail.isEmpty ? "\(name) failed with status \(process.terminationStatus)." : detail)
    }
    return CommandOutput(standardOutput: stdout, standardError: stderr)
  }

  /// Runs a command and keeps only the lines `keepLine` accepts.
  ///
  /// Unlike `run`, output size is bounded by what is *kept*, not by what is produced,
  /// so a command that emits tens of megabytes costs whatever the caller asked for.
  func runStreaming(
    _ executablePath: String,
    arguments: [String],
    keepLine: @escaping @Sendable (Data.SubSequence) -> Bool
  ) throws -> StreamedCommandOutput {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw FixedCommandError.missingExecutable(executablePath)
    }

    let process = Process()
    let output = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(["LC_ALL": "C"]) { _, fixed in fixed }
    process.standardOutput = output
    process.standardError = errorPipe

    let group = DispatchGroup()
    let capture = LineFilteringCapture(keepLine: keepLine)
    // stderr stays bounded and buffered: it is short, and its content is the error text.
    let errorCapture = BoundedPipeCapture(maximumBytes: 256 * 1_024)
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      capture.read(from: output.fileHandleForReading)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      errorCapture.read(from: errorPipe.fileHandleForReading)
      group.leave()
    }

    do {
      try process.run()
    } catch {
      output.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      group.wait()
      throw error
    }

    let deadline = DispatchTime.now() + timeout
    var timedOut = false
    while process.isRunning {
      if DispatchTime.now() >= deadline {
        timedOut = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      let terminationDeadline = DispatchTime.now() + 1
      while process.isRunning, DispatchTime.now() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
    group.wait()

    let name = URL(fileURLWithPath: executablePath).lastPathComponent
    if timedOut { throw FixedCommandError.timedOut(name) }

    let result = capture.snapshot()
    guard process.terminationStatus == 0 else {
      let detail = String(decoding: errorCapture.snapshot().data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw FixedCommandError.failed(
        detail.isEmpty ? "\(name) failed with status \(process.terminationStatus)." : detail)
    }
    return StreamedCommandOutput(
      lines: result.lines,
      bytesRead: result.bytesSeen,
      isPartial: result.droppedOversizedLine
    )
  }
}

protocol PowerDiagnosticsProbing {
  func batteryStatus() throws -> BatteryStatus?
  func wakeStatistics() throws -> WakeStatistics
  func wakeEvents() throws -> [WakeEvent]
  func powerProfiles() throws -> PowerProfiles
  func sleepAssertions() throws -> [SleepAssertion]
  func scheduledWakes() throws -> [ScheduledWake]
}

extension PowerDiagnosticsProbing {
  // Defaulted so existing test doubles keep compiling; the real probe overrides both.
  func sleepAssertions() throws -> [SleepAssertion] { [] }
  func scheduledWakes() throws -> [ScheduledWake] { [] }
}

struct SystemPowerDiagnosticsProbe: PowerDiagnosticsProbing {
  private let runner = FixedCommandRunner()

  func batteryStatus() throws -> BatteryStatus? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }

    for source in sources {
      guard let values = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
        as? [String: Any],
        values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = values[kIOPSCurrentCapacityKey] as? Int,
        let maximum = values[kIOPSMaxCapacityKey] as? Int,
        maximum > 0
      else { continue }

      let sourceState = values[kIOPSPowerSourceStateKey] as? String
      let onAC = sourceState.map { $0 == kIOPSACPowerValue }
      let charging = values[kIOPSIsChargingKey] as? Bool
      let time = values[kIOPSTimeToEmptyKey] as? Int
      let registry = try? runner.run("/usr/sbin/ioreg", arguments: ["-rn", "AppleSmartBattery"])
      let flow = registry.flatMap { try? PowerDiagnosticsParser.parseBatteryRegistry($0.standardOutput) }
      return BatteryStatus(
        percentage: min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded()))),
        isCharging: charging,
        isOnAC: onAC,
        timeRemainingMinutes: (time ?? 0) > 0 ? time : nil,
        flow: flow)
    }
    return nil
  }

  func wakeStatistics() throws -> WakeStatistics {
    let output = try runner.run("/usr/bin/pmset", arguments: ["-g", "stats"])
    return try PowerDiagnosticsParser.parseWakeStats(output.standardOutput)
  }

  func wakeEvents() throws -> [WakeEvent] {
    // Streamed, not buffered: `pmset -g log` is tens of megabytes and almost all of it
    // is the Assertions domain, which this call does not read.
    // `pmset -g log` itself takes 5.4 s on this Mac and grows with uptime, so the
    // 12 s default leaves too little headroom. This runs on a background queue.
    var reader = runner
    reader.timeout = 45
    let output = try reader.runStreaming(
      "/usr/bin/pmset",
      arguments: ["-g", "log"],
      keepLine: { PowerDiagnosticsParser.isInterestingLogLine($0) }
    )
    return try PowerDiagnosticsParser.parseWakeEvents(output.lines.joined(separator: "\n"))
  }

  func sleepAssertions() throws -> [SleepAssertion] {
    let output = try runner.run("/usr/bin/pmset", arguments: ["-g", "assertions"])
    return PowerAttributionParser.parseAssertions(output.standardOutput)
  }

  func scheduledWakes() throws -> [ScheduledWake] {
    var reader = runner
    reader.timeout = 45
    let output = try reader.runStreaming("/usr/bin/pmset", arguments: ["-g", "log"]) { line in
      let prefix = 26
      guard line.count > prefix else { return false }
      return line[line.index(line.startIndex, offsetBy: prefix)...]
        .starts(with: Array("Wake Requests".utf8))
    }
    return PowerAttributionParser.parseScheduledWakes(output.lines.joined(separator: "\n"))
  }

  func powerProfiles() throws -> PowerProfiles {
    let output = try runner.run("/usr/bin/pmset", arguments: ["-g", "custom"])
    return try PowerDiagnosticsParser.parsePowerProfiles(output.standardOutput)
  }
}
