import AppKit
import Combine
import Foundation

struct ProcessHealthProcess: Identifiable, Equatable {
  let pid: Int32
  let parentPID: Int32
  let state: String
  let cpuPercent: Double
  let memoryPercent: Double
  let command: String
  let threadCount: Int

  var id: Int32 { pid }
  var isZombie: Bool { state.uppercased().hasPrefix("Z") }
}

struct ProcessHealthSnapshot: Equatable {
  let processes: [ProcessHealthProcess]
  let totalThreads: Int
  let scannedAt: Date

  var zombies: [ProcessHealthProcess] { processes.filter(\.isZombie) }
  var busiestProcesses: [ProcessHealthProcess] {
    processes.sorted {
      $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent
    }
  }
  var mostThreadedProcesses: [ProcessHealthProcess] {
    processes.sorted {
      $0.threadCount == $1.threadCount ? $0.pid < $1.pid : $0.threadCount > $1.threadCount
    }
  }
}

enum ProcessHealthParseError: LocalizedError {
  case noRows

  var errorDescription: String? { "No process health rows were found." }
}

enum ProcessHealthParser {
  /// `ps -M` emits one row per thread. Collapsing by PID preserves process state while
  /// giving the manual scan a truthful thread total without a background sampler.
  static func parsePS(_ text: String, scannedAt: Date = Date()) throws -> ProcessHealthSnapshot {
    struct Aggregate {
      var parentPID: Int32
      var state: String
      var cpuPercent: Double
      var memoryPercent: Double
      var command: String
      var threadCount = 0
    }

    var aggregates: [Int32: Aggregate] = [:]
    var totalThreads = 0
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let fields = rawLine.split(maxSplits: 5, whereSeparator: \.isWhitespace)
      guard fields.count == 6,
        let pid = Int32(fields[0]),
        let parentPID = Int32(fields[1]),
        let cpuPercent = Double(fields[3]),
        let memoryPercent = Double(fields[4])
      else { continue }

      totalThreads += 1
      if var aggregate = aggregates[pid] {
        aggregate.threadCount += 1
        aggregates[pid] = aggregate
      } else {
        aggregates[pid] = Aggregate(
          parentPID: parentPID,
          state: String(fields[2]),
          cpuPercent: cpuPercent,
          memoryPercent: memoryPercent,
          command: String(fields[5]),
          threadCount: 1)
      }
    }

    guard !aggregates.isEmpty else { throw ProcessHealthParseError.noRows }
    let processes = aggregates.map { pid, aggregate in
      ProcessHealthProcess(
        pid: pid,
        parentPID: aggregate.parentPID,
        state: aggregate.state,
        cpuPercent: aggregate.cpuPercent,
        memoryPercent: aggregate.memoryPercent,
        command: aggregate.command,
        threadCount: aggregate.threadCount)
    }
    return ProcessHealthSnapshot(processes: processes, totalThreads: totalThreads, scannedAt: scannedAt)
  }
}

protocol ProcessHealthProbing {
  func scan() throws -> ProcessHealthSnapshot
}

struct SystemProcessHealthProbe: ProcessHealthProbing {
  private let runner = FixedCommandRunner(timeout: 10, maximumOutputBytes: 4 * 1_024 * 1_024)

  func scan() throws -> ProcessHealthSnapshot {
    let output = try runner.run(
      "/bin/ps",
      arguments: ["-M", "-axo", "pid=,ppid=,state=,pcpu=,pmem=,comm="])
    return try ProcessHealthParser.parsePS(output.standardOutput)
  }
}

final class ProcessHealthService: ObservableObject {
  @Published private(set) var snapshot: ProcessHealthSnapshot?
  @Published private(set) var isAnalyzing = false
  @Published private(set) var errorMessage: String?

  private let probe: ProcessHealthProbing
  private let queue = DispatchQueue(label: "com.tagzxia.app.menucue.process-health", qos: .utility)

  init(probe: ProcessHealthProbing = SystemProcessHealthProbe()) {
    self.probe = probe
  }

  /// A deliberate user request only. Process/thread enumeration never runs on a timer.
  func analyze() {
    guard !isAnalyzing else { return }
    isAnalyzing = true
    errorMessage = nil
    queue.async { [weak self] in
      guard let self else { return }
      let result = Result { try self.probe.scan() }
      DispatchQueue.main.async {
        switch result {
        case .success(let snapshot): self.snapshot = snapshot
        case .failure(let error): self.errorMessage = error.localizedDescription
        }
        self.isAnalyzing = false
      }
    }
  }

  func openActivityMonitor() {
    let applicationURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init()) { [weak self] app, error in
      guard app == nil, let error else { return }
      DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
    }
  }
}
