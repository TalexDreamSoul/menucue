import Foundation

enum WakeEventKind: String, Codable, CaseIterable {
  case sleep
  case darkWake
  case wake
}

struct WakeStatistics: Equatable, Codable {
  let sleepCount: Int
  let darkWakeCount: Int
  let userWakeCount: Int
}

struct WakeEvent: Identifiable, Equatable, Hashable, Codable {
  let timestamp: Date
  let kind: WakeEventKind
  let reason: String
  let occurrence: Int

  var id: String {
    let millis = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
    return "\(millis)|\(kind.rawValue)|\(reason)|\(occurrence)"
  }
}

struct WakeDailySummary: Identifiable, Equatable, Codable {
  let day: Date
  let sleepCount: Int
  let darkWakeCount: Int
  let userWakeCount: Int

  var id: Date { day }
}

enum PowerMode: Equatable, Codable {
  case normal
  case low
  case high
  case other(Int)
}

struct PowerProfile: Equatable, Codable {
  var powerMode: PowerMode?
  var powerNap: Bool?
  var wakeOnNetwork: Bool?
  var standby: Bool?
  var tcpKeepalive: Bool?
  var diskSleepMinutes: Int?
  var displaySleepMinutes: Int?
}

struct PowerProfiles: Equatable, Codable {
  var battery: PowerProfile?
  var ac: PowerProfile?
  var ups: PowerProfile?
}

struct BatteryFlow: Equatable, Codable {
  let watts: Double
  let percentPerHour: Double
}

struct PowerDiagnosticsSnapshot: Equatable {
  var wakeStatistics: WakeStatistics?
  var events: [WakeEvent] = []
  var dailySummaries: [WakeDailySummary] = []
  var profiles = PowerProfiles()
  var batteryFlow: BatteryFlow?
  var refreshedAt: Date?
  var errorMessage: String?

  func darkWakeCount(on date: Date, calendar: Calendar = .current) -> Int {
    let day = calendar.startOfDay(for: date)
    return dailySummaries.first { calendar.isDate($0.day, inSameDayAs: day) }?.darkWakeCount ?? 0
  }
}

enum PowerDiagnosticsParseError: LocalizedError {
  case missingField(String)
  case malformed(String)

  var errorDescription: String? {
    switch self {
    case .missingField(let field): return "Missing power diagnostics field: \(field)"
    case .malformed(let source): return "Could not parse power diagnostics output: \(source)"
    }
  }
}

enum PowerDiagnosticsParser {
  private enum ProfileSection {
    case battery
    case ac
    case ups
  }

  static func parseWakeStats(_ text: String) throws -> WakeStatistics {
    func value(_ label: String) throws -> Int {
      guard
        let line = text.split(whereSeparator: \.isNewline).first(where: {
          $0.trimmingCharacters(in: .whitespaces).hasPrefix(label + ":")
        }),
        let separator = line.firstIndex(of: ":"),
        let result = Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
      else { throw PowerDiagnosticsParseError.missingField(label) }
      return result
    }

    return try WakeStatistics(
      sleepCount: value("Sleep Count"),
      darkWakeCount: value("Dark Wake Count"),
      userWakeCount: value("User Wake Count")
    )
  }

  static func parseWakeEvents(_ text: String) throws -> [WakeEvent] {
    let pattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([+-]\d{4})\s+(Sleep|DarkWake|Wake)\s+(.+)$"#
    let expression = try NSRegularExpression(pattern: pattern)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    var occurrences: [String: Int] = [:]
    var events: [WakeEvent] = []
    for line in text.split(whereSeparator: \.isNewline).map(String.init) {
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges == 5,
        let dateRange = Range(match.range(at: 1), in: line),
        let zoneRange = Range(match.range(at: 2), in: line),
        let kindRange = Range(match.range(at: 3), in: line),
        let messageRange = Range(match.range(at: 4), in: line),
        let date = formatter.date(from: "\(line[dateRange]) \(line[zoneRange])")
      else { continue }

      let kind: WakeEventKind
      switch line[kindRange] {
      case "Sleep": kind = .sleep
      case "DarkWake": kind = .darkWake
      case "Wake": kind = .wake
      default: continue
      }
      let reason = wakeReason(from: String(line[messageRange]))
      let signature = "\(date.timeIntervalSince1970)|\(kind.rawValue)|\(reason)"
      let occurrence = occurrences[signature, default: 0]
      occurrences[signature] = occurrence + 1
      events.append(
        WakeEvent(timestamp: date, kind: kind, reason: reason, occurrence: occurrence))
    }
    return events.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
      return lhs.occurrence < rhs.occurrence
    }
  }

  static func parsePowerProfiles(_ text: String) throws -> PowerProfiles {
    var section: ProfileSection?
    var profiles = PowerProfiles()

    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      switch line {
      case "Battery Power:": section = .battery; if profiles.battery == nil { profiles.battery = PowerProfile() }
      case "AC Power:": section = .ac; if profiles.ac == nil { profiles.ac = PowerProfile() }
      case "UPS Power:": section = .ups; if profiles.ups == nil { profiles.ups = PowerProfile() }
      default:
        guard let section else { continue }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { continue }
        let key = String(fields[0]).lowercased()
        let value = Int(fields[1])
        mutateProfile(in: &profiles, section: section) { profile in
          switch key {
          case "powermode", "lowpowermode":
            if let value { profile.powerMode = powerMode(value) }
          case "powernap": profile.powerNap = bool(value)
          case "womp": profile.wakeOnNetwork = bool(value)
          case "standby": profile.standby = bool(value)
          case "tcpkeepalive": profile.tcpKeepalive = bool(value)
          case "disksleep": profile.diskSleepMinutes = value
          case "displaysleep": profile.displaySleepMinutes = value
          default: break
          }
        }
      }
    }

    guard profiles.battery != nil || profiles.ac != nil || profiles.ups != nil else {
      throw PowerDiagnosticsParseError.malformed("pmset -g custom")
    }
    return profiles
  }

  static func parseBatteryRegistry(_ text: String) throws -> BatteryFlow {
    func signed(_ key: String) throws -> Int64 {
      let pattern = "\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*=\\s*(\\d+)"
      let expression = try NSRegularExpression(pattern: pattern)
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = expression.firstMatch(in: text, range: range),
        let valueRange = Range(match.range(at: 1), in: text),
        let unsigned = UInt64(text[valueRange])
      else { throw PowerDiagnosticsParseError.missingField(key) }
      return Int64(bitPattern: unsigned)
    }

    let amperage = try signed("InstantAmperage")
    let voltage = try signed("Voltage")
    let capacity = try signed("AppleRawMaxCapacity")
    guard capacity > 0 else { throw PowerDiagnosticsParseError.malformed("battery capacity") }
    return BatteryFlow(
      watts: Double(voltage) / 1_000 * Double(amperage) / 1_000,
      percentPerHour: Double(amperage) / Double(capacity) * 100
    )
  }

  private static func wakeReason(from message: String) -> String {
    guard let range = message.range(of: "due to ") else {
      return message.trimmingCharacters(in: .whitespaces)
    }
    var reason = String(message[range.upperBound...])
    if reason.first == "'", let close = reason.dropFirst().firstIndex(of: "'") {
      return String(reason[reason.index(after: reason.startIndex)..<close])
        .trimmingCharacters(in: .whitespaces)
    }
    if let usingRange = reason.range(of: " Using") {
      reason = String(reason[..<usingRange.lowerBound])
    }
    return reason.trimmingCharacters(in: .whitespaces)
  }

  private static func bool(_ value: Int?) -> Bool? {
    guard let value, value == 0 || value == 1 else { return nil }
    return value == 1
  }

  private static func powerMode(_ value: Int) -> PowerMode {
    switch value {
    case 0: return .normal
    case 1: return .low
    case 2: return .high
    default: return .other(value)
    }
  }

  private static func mutateProfile(
    in profiles: inout PowerProfiles,
    section: ProfileSection,
    mutation: (inout PowerProfile) -> Void
  ) {
    switch section {
    case .battery: mutation(&profiles.battery!)
    case .ac: mutation(&profiles.ac!)
    case .ups: mutation(&profiles.ups!)
    }
  }
}
