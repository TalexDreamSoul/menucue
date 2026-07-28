import Darwin
import Foundation

struct ProcessDetail: Equatable {
  let identity: ProcessIdentity
  let parentPID: Int32
  let userName: String
  let cpuPercent: Double
  let memoryPercent: Double
  let nice: Int
  let elapsed: String
  let bundleIdentifier: String?
  let bundleVersion: String?
}

protocol ProcessEnergyProbing {
  func sample(limit: Int) throws -> [ProcessEnergyEntry]
  func detail(for identity: ProcessIdentity) throws -> ProcessDetail
  func currentIdentity(pid: Int32) -> ProcessIdentity?
}

struct SystemProcessEnergyProbe: ProcessEnergyProbing {
  private let runner = FixedCommandRunner(timeout: 10)

  func sample(limit: Int = 12) throws -> [ProcessEnergyEntry] {
    let fetch = max(20, limit * 2)
    let output = try runner.run(
      "/usr/bin/top",
      arguments: ["-l", "2", "-n", "\(fetch)", "-stats", "pid,command,power", "-o", "power"])
    let rows = try ProcessEnergyParser.parseTop(output.standardOutput)
    return rows.compactMap { row in
      guard let identity = currentIdentity(pid: row.pid) else { return nil }
      let name = processName(pid: row.pid) ?? row.sampledName
      return ProcessEnergyEntry(
        identity: identity,
        name: name,
        appName: appName(executablePath: identity.executablePath, fallback: name),
        energyImpact: row.energyImpact)
    }.prefix(limit).map { $0 }
  }

  func detail(for identity: ProcessIdentity) throws -> ProcessDetail {
    guard currentIdentity(pid: identity.pid) == identity else { throw ProcessActionError.staleIdentity }
    let output = try runner.run(
      "/bin/ps",
      arguments: ["-p", "\(identity.pid)", "-o", "ppid=,user=,%cpu=,%mem=,nice=,etime="])
    let fields = output.standardOutput.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 6,
      let parentPID = Int32(fields[0]),
      let cpu = Double(fields[2]),
      let memory = Double(fields[3]),
      let nice = Int(fields[4])
    else { throw ProcessActionError.exited }

    let bundlePath = identity.executablePath.range(of: ".app/").map { range in
      String(identity.executablePath[..<identity.executablePath.index(before: range.upperBound)])
    }
    let bundle = bundlePath.flatMap(Bundle.init(path:))
    return ProcessDetail(
      identity: identity,
      parentPID: parentPID,
      userName: String(fields[1]),
      cpuPercent: cpu,
      memoryPercent: memory,
      nice: nice,
      elapsed: String(fields[5]),
      bundleIdentifier: bundle?.bundleIdentifier,
      bundleVersion: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
  }

  func currentIdentity(pid: Int32) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return ProcessIdentity(
      pid: pid,
      startTime: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000,
      ownerUID: info.pbi_uid,
      executablePath: String(cString: buffer))
  }

  private func processName(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  private func appName(executablePath: String, fallback: String) -> String? {
    guard let range = executablePath.range(of: ".app/") else { return nil }
    let appPath = String(executablePath[..<executablePath.index(before: range.upperBound)])
    return (Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
  }
}

enum ProcessActionError: LocalizedError {
  case staleIdentity
  case exited
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .staleIdentity: return "The process changed before the action could run."
    case .exited: return "The process is no longer running."
    case .failed(let message): return message
    }
  }
}
