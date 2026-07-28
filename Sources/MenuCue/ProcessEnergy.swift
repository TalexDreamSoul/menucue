import Darwin
import Foundation

struct ProcessIdentity: Hashable, Codable {
  let pid: Int32
  let startTime: TimeInterval
  let ownerUID: UInt32
  let executablePath: String

  static func fixture(pid: Int32) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startTime: Double(pid), ownerUID: 501, executablePath: "/fixture/\(pid)")
  }
}

struct RawProcessEnergyRow: Equatable {
  let pid: Int32
  let sampledName: String
  let energyImpact: Double
}

struct ProcessEnergyEntry: Identifiable, Equatable {
  let identity: ProcessIdentity
  let name: String
  let appName: String?
  let energyImpact: Double
  var id: ProcessIdentity { identity }
}

struct ProcessEnergyGroup: Identifiable, Equatable {
  let name: String
  let energyImpact: Double
  let members: [ProcessEnergyEntry]
  var id: String { name }
}

enum ProcessControlPolicy {
  static func requiresStrongConfirmation(
    for identity: ProcessIdentity,
    currentUID: UInt32 = getuid()
  ) -> Bool {
    if identity.ownerUID != currentUID { return true }
    let protectedPrefixes = [
      "/System/", "/Library/Apple/", "/usr/bin/", "/usr/libexec/", "/usr/sbin/", "/bin/", "/sbin/",
    ]
    return protectedPrefixes.contains { identity.executablePath.hasPrefix($0) }
  }
}

enum ProcessEnergyParseError: LocalizedError {
  case noRows

  var errorDescription: String? { "No process energy rows were found." }
}

enum ProcessEnergyParser {
  static func parseTop(_ text: String) throws -> [RawProcessEnergyRow] {
    var rows: [RawProcessEnergyRow] = []
    var inTable = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("PID"), line.contains("COMMAND"), line.contains("POWER") {
        rows.removeAll(keepingCapacity: true)
        inTable = true
        continue
      }
      guard inTable else { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 3, let pid = Int32(fields[0]), let impact = Double(fields.last!) else {
        continue
      }
      rows.append(
        RawProcessEnergyRow(
          pid: pid,
          sampledName: fields.dropFirst().dropLast().joined(separator: " "),
          energyImpact: impact))
    }
    guard !rows.isEmpty else { throw ProcessEnergyParseError.noRows }
    return rows.sorted { $0.energyImpact > $1.energyImpact }
  }
}

enum ProcessEnergyAggregator {
  static func groups(from entries: [ProcessEnergyEntry]) -> [ProcessEnergyGroup] {
    let grouped = Dictionary(grouping: entries) { entry in
      entry.appName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        ?? displayName(for: entry.name)
    }
    return grouped.map { name, members in
      ProcessEnergyGroup(
        name: name,
        energyImpact: members.reduce(0) { $0 + $1.energyImpact },
        members: members.sorted { $0.identity.pid < $1.identity.pid })
    }.sorted { lhs, rhs in
      if lhs.energyImpact != rhs.energyImpact { return lhs.energyImpact > rhs.energyImpact }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private static func displayName(for processName: String) -> String {
    guard let range = processName.range(of: " Helper") else { return processName }
    let base = String(processName[..<range.lowerBound])
    return base.isEmpty ? processName : base
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
