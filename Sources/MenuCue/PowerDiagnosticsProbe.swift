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
}

protocol PowerDiagnosticsProbing {
  func batteryStatus() throws -> BatteryStatus?
  func wakeStatistics() throws -> WakeStatistics
  func wakeEvents() throws -> [WakeEvent]
  func powerProfiles() throws -> PowerProfiles
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
    let output = try runner.run("/usr/bin/pmset", arguments: ["-g", "log"])
    return try PowerDiagnosticsParser.parseWakeEvents(output.standardOutput)
  }

  func powerProfiles() throws -> PowerProfiles {
    let output = try runner.run("/usr/bin/pmset", arguments: ["-g", "custom"])
    return try PowerDiagnosticsParser.parsePowerProfiles(output.standardOutput)
  }
}
