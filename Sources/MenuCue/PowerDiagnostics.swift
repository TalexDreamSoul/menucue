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
  /// The UTC offset in force where and when this happened.
  ///
  /// Optional so files written before this existed still decode. Daily buckets used
  /// `Calendar.current` at *load* time, so flying somewhere re-dated every historical
  /// event; bucketing by the offset that was recorded keeps a night in Shanghai a
  /// night in Shanghai.
  var utcOffsetSeconds: Int?

  /// Identity that survives a parser change.
  ///
  /// `reason` used to be part of this. That made the id a hostage to the parsing: any
  /// improvement to how a reason is derived silently orphaned every record already on
  /// disk, because the same event would no longer match itself. `occurrence` is
  /// counted per (timestamp, kind), which is what keeps two different events in the
  /// same second distinct without depending on their text.
  var id: String {
    let millis = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
    return "\(millis)|\(kind.rawValue)|\(occurrence)"
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

/// Live power-path telemetry from AppleSmartBattery. All fields optional because
/// availability differs by hardware: `PowerTelemetryData` is Apple-Silicon-only, and
/// `AdapterDetails.Watts` exists only while an adapter is attached.
struct PowerTelemetry: Equatable, Codable {
  /// `AdapterDetails.Watts` — the adapter's rated output. 0/absent maps to nil.
  var adapterRatedWatts: Int?
  /// `PowerTelemetryData.SystemPowerIn`, converted from milliwatts.
  var systemInWatts: Double?
  /// `PowerTelemetryData.SystemLoad`, converted from milliwatts.
  var systemLoadWatts: Double?
}

/// Which way power is moving right now, classified for the Battery Flow card's
/// Sankey view. `nil` from `make` means telemetry is insufficient and the card keeps
/// its flat-bar layout.
enum PowerFlowState: Equatable {
  case charging(adapterW: Double, batteryW: Double, systemW: Double, ratedW: Int?)
  case directSupply(systemW: Double, ratedW: Int?)
  case batteryAssist(adapterW: Double, batteryW: Double, systemW: Double, ratedW: Int?)
  case onBattery(dischargeW: Double)

  /// Battery branch watts come from `flow.watts` (InstantAmperage × Voltage), whose
  /// sign convention the existing parser proves; telemetry's `BatteryPower` field is
  /// deliberately unused because its sign semantics are unverified. The ±0.5 W band
  /// keeps trickle noise from flapping the layout between states.
  static func make(battery: BatteryStatus) -> PowerFlowState? {
    guard let isOnAC = battery.isOnAC, let flow = battery.flow else { return nil }
    if !isOnAC {
      // ≥ −0.05 is the idle/sleep edge: render a 0.0 W ribbon rather than no card.
      return .onBattery(dischargeW: flow.watts >= -0.05 ? 0 : -flow.watts)
    }
    guard let telemetry = battery.telemetry, let systemLoad = telemetry.systemLoadWatts
    else { return nil }
    let rated = telemetry.adapterRatedWatts
    let systemIn = telemetry.systemInWatts
    if flow.watts > 0.5 {
      return .charging(
        adapterW: systemIn ?? (systemLoad + flow.watts),
        batteryW: flow.watts,
        systemW: systemLoad,
        ratedW: rated)
    }
    if flow.watts < -0.5 {
      let discharge = -flow.watts
      return .batteryAssist(
        adapterW: systemIn ?? max(0, systemLoad - discharge),
        batteryW: discharge,
        systemW: systemLoad,
        ratedW: rated)
    }
    return .directSupply(systemW: systemIn ?? systemLoad, ratedW: rated)
  }
}

extension BatteryStatus {
  /// Runtime estimate for the card header, deliberately pessimistic: naive
  /// percentage-over-rate projections and the OS's own figure both run optimistic, and
  /// an estimate that under-promises reads as honest. Takes the smaller of the two
  /// sources, then a further 10% haircut. nil while charging, while drain is inside
  /// the trickle band, or beyond 24 h — an idle-noise projection, not a runtime.
  var conservativeRuntimeMinutes: Int? {
    guard isCharging != true else { return nil }
    var candidates: [Double] = []
    if let minutes = timeRemainingMinutes { candidates.append(Double(minutes)) }
    if let rate = flow?.percentPerHour, rate < -0.1 {
      candidates.append(Double(percentage) / -rate * 60)
    }
    guard let smallest = candidates.min() else { return nil }
    let discounted = Int(smallest * 0.9)
    return discounted <= 1_440 ? discounted : nil
  }
}

struct PowerDiagnosticsSnapshot: Equatable {
  var wakeStatistics: WakeStatistics?
  var events: [WakeEvent] = []
  var dailySummaries: [WakeDailySummary] = []
  var profiles = PowerProfiles()
  var batteryFlow: BatteryFlow?
  /// Currently held power assertions — what is keeping this Mac awake right now.
  var assertions: [SleepAssertion] = []
  /// Wakes the system planned. Never rendered as wakes that happened; used only to
  /// attribute the ones that did.
  var scheduledWakes: [ScheduledWake] = []
  var refreshedAt: Date?
  var errorMessage: String?

  /// The most recent thing that actually woke the Mac, with the best cause available.
  var latestWake: (event: WakeEvent, cause: WakeCause)? {
    guard let event = events.last(where: { $0.kind != .sleep }) else { return nil }
    return (
      event,
      PowerAttributionParser.attribute(
        wakeAt: event.timestamp, interruptToken: event.reason, scheduled: scheduledWakes)
    )
  }

  /// Assertions that stop the machine sleeping, longest-held first — the ones worth
  /// telling someone about.
  var sleepBlockers: [SleepAssertion] {
    assertions.filter(\.preventsSystemSleep).sorted { $0.heldSeconds > $1.heldSeconds }
  }

  /// `nil` when there is no record for that day at all.
  ///
  /// The old `?? 0` rendered "0 dark wakes today" whether the Mac genuinely had none
  /// or the history simply had not been read — indistinguishable, and the second is
  /// what every user saw while the log was blowing the size cap.
  func darkWakeCount(on date: Date, calendar: Calendar = .current) -> Int? {
    let day = calendar.startOfDay(for: date)
    return dailySummaries.first { calendar.isDate($0.day, inSameDayAs: day) }?.darkWakeCount
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

  /// Matches only the domains that record something which *happened*.
  ///
  /// The `(?!\s+Requests)` is the whole point. `pmset` pads its domain column, so a
  /// bare `Wake\s+` also matches the `Wake Requests` domain — lines written at *sleep*
  /// time listing wakes scheduled for the *future*. Around 30% of what this parser
  /// returned were those: shown as wakes that had occurred, counted in the daily
  /// totals, and persisted with a 500-character blob as their reason.
  ///
  /// Scheduled wakes now parse separately into `ScheduledWake`, so they cannot reach
  /// `WakeEvent` by any path — the defect is structurally impossible rather than fixed.
  static let wakeEventPattern =
    #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([+-]\d{4})\s+(Sleep|DarkWake|Wake)(?!\s+Requests)\s+(.+)$"#

  /// True when a raw log line is one this feature reads at all.
  ///
  /// Used as the streaming filter, which is what keeps the 23.9 MB of `Assertions`
  /// lines out of memory entirely.
  static func isInterestingLogLine(_ line: String) -> Bool {
    isInterestingLogLine(Data(line.utf8)[...])
  }

  /// Byte-level form, used as the streaming filter. Runs on every one of the ~105,000
  /// lines `pmset -g log` emits, so it never allocates.
  static func isInterestingLogLine(_ line: Data.SubSequence) -> Bool {
    // The domain column starts after "yyyy-MM-dd HH:mm:ss ±ZZZZ ".
    let prefixLength = 26
    guard line.count > prefixLength else { return false }
    let domainStart = line.index(line.startIndex, offsetBy: prefixLength)
    let domain = line[domainStart...]
    return domain.starts(with: sleepPrefix) || domain.starts(with: wakePrefix)
      || domain.starts(with: darkWakePrefix)
  }

  private static let sleepPrefix = Array("Sleep".utf8)
  private static let wakePrefix = Array("Wake".utf8)
  private static let darkWakePrefix = Array("DarkWake".utf8)

  static func parseWakeEvents(_ text: String) throws -> [WakeEvent] {
    let expression = try NSRegularExpression(pattern: wakeEventPattern)
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
      // Keyed without the reason, matching `id`: two events of the same kind in the
      // same second are distinguished by order, not by what they say.
      let signature = "\(date.timeIntervalSince1970)|\(kind.rawValue)"
      let occurrence = occurrences[signature, default: 0]
      occurrences[signature] = occurrence + 1
      // The log line carries its own offset, so a historical event keeps the zone it
      // actually happened in even after the user travels.
      let offsetText = String(line[zoneRange])
      let offsetSeconds = Int(offsetText.prefix(3)).map { hours in
        let minutes = Int(offsetText.suffix(2)) ?? 0
        return hours * 3_600 + (hours < 0 ? -minutes : minutes) * 60
      }
      events.append(
        WakeEvent(
          timestamp: date, kind: kind, reason: reason, occurrence: occurrence,
          utcOffsetSeconds: offsetSeconds))
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
    /// Reads a **top-level** `ioreg` property.
    ///
    /// Two things this has to get right, both of which it used to get wrong:
    ///
    /// * Anchoring. `ioreg` prints nested dictionaries inline, so `BatteryData` is one
    ///   enormous line carrying `"Voltage"=12345` among hundreds of other keys. A
    ///   whole-text `firstMatch` found that one, tens of lines before the real
    ///   top-level `"Voltage" = 12345`. Top-level properties sit alone on a line with
    ///   spaces around the `=`; nested ones never do.
    /// * Sign. The pattern accepted digits only, so a negative literal would have had
    ///   its minus dropped — reporting charging while discharging. Values can also
    ///   arrive as unsigned two's complement, which the `bitPattern` conversion covers.
    func signed(_ key: String) throws -> Int64 {
      let escaped = NSRegularExpression.escapedPattern(for: key)
      // The prefix allows `ioreg`'s tree drawing (`| |   `) as well as plain
      // indentation. What actually discriminates is the tail: a top-level property
      // ends the line, while a key inside an inline dictionary is always followed by
      // a comma or a brace.
      let pattern = "^[\\s|+\\-]*\\\"\(escaped)\\\" = (-?\\d+)\\s*$"
      let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = expression.firstMatch(in: text, range: range),
        let valueRange = Range(match.range(at: 1), in: text)
      else { throw PowerDiagnosticsParseError.missingField(key) }

      let literal = String(text[valueRange])
      if let value = Int64(literal) { return value }
      // Beyond Int64 means an unsigned two's-complement negative.
      guard let unsigned = UInt64(literal) else {
        throw PowerDiagnosticsParseError.malformed(key)
      }
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

  /// Reads adapter and power-path telemetry from the same `ioreg -rn AppleSmartBattery`
  /// output `parseBatteryRegistry` consumes. Returns nil only when nothing useful was
  /// found; individual fields stay optional because availability differs by hardware.
  static func parsePowerTelemetry(_ text: String) -> PowerTelemetry? {
    /// Captures the single-line inline dictionary of a **top-level** property.
    ///
    /// The same anchoring problem `signed` documents applies here in dictionary form:
    /// `AppleRawAdapterDetails` is a different top-level line that also carries
    /// `"Watts"=`, so the property name must match exactly at the start of the line.
    /// Requiring ` = {` additionally excludes it, since arrays print as ` = (`.
    func inlineDictionary(_ key: String) -> String? {
      let escaped = NSRegularExpression.escapedPattern(for: key)
      let pattern = "^[\\s|+\\-]*\\\"\(escaped)\\\" = \\{(.*)$"
      guard
        let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
        let match = expression.firstMatch(
          in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
        let payloadRange = Range(match.range(at: 1), in: text)
      else { return nil }
      return String(text[payloadRange])
    }

    /// Reads one `"Key"=value` entry inside a captured payload. The quotes are the
    /// anchors: `"SystemPowerIn"=` cannot match inside `"SystemPowerInAccumulatorCount"=`
    /// (no closing quote there) or `"AccumulatedSystemLoad"=` (no opening quote).
    func field(_ payload: String, _ key: String) -> Int64? {
      let escaped = NSRegularExpression.escapedPattern(for: key)
      let pattern = "\\\"\(escaped)\\\"=(\\d+)"
      guard
        let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
          in: payload, range: NSRange(payload.startIndex..<payload.endIndex, in: payload)),
        let valueRange = Range(match.range(at: 1), in: payload)
      else { return nil }
      // Values beyond Int64 are unsigned two's-complement noise for these keys; treat
      // the field as absent rather than reporting an absurd wattage.
      return Int64(payload[valueRange])
    }

    var telemetry = PowerTelemetry()
    // Unplugged Macs print `"AdapterDetails" = {}` or a dictionary with `Watts=0`.
    if let adapter = inlineDictionary("AdapterDetails"),
      let watts = field(adapter, "Watts"), watts > 0
    {
      telemetry.adapterRatedWatts = Int(watts)
    }
    if let payload = inlineDictionary("PowerTelemetryData") {
      if let milliwatts = field(payload, "SystemPowerIn") {
        telemetry.systemInWatts = Double(milliwatts) / 1_000
      }
      if let milliwatts = field(payload, "SystemLoad") {
        telemetry.systemLoadWatts = Double(milliwatts) / 1_000
      }
    }
    return telemetry == PowerTelemetry() ? nil : telemetry
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
