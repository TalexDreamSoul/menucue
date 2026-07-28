import Foundation

// MARK: - Scheduled wakes

/// A wake the system *planned*, recorded at sleep time.
///
/// Deliberately a separate type from `WakeEvent`. These lines used to match the wake
/// regex and appear as wakes that had happened — roughly a third of the list. Keeping
/// them in their own type is what makes that impossible rather than merely fixed.
struct ScheduledWake: Equatable {
  let loggedAt: Date
  let wakeAt: Date
  let process: String
  let request: String
  let info: String?
  /// `pmset` marks the request that will fire first with `*`. Only that one can be the
  /// cause of the wake that follows.
  let isWinning: Bool
}

// MARK: - Why the Mac woke

/// What woke the Mac, in the most specific form available.
enum WakeCause: Equatable {
  /// A named process asked for this wake in advance.
  case process(name: String, request: String, detail: String?)
  /// Only the hardware interrupt is known. `plain` is the human reading of `token`.
  case interrupt(token: String, plain: String)
  /// Nothing usable was recorded. Never guessed at.
  case unknown

  /// One sentence, for the top of the pane.
  var sentence: String {
    switch self {
    case let .process(name, _, detail):
      if let detail, !detail.isEmpty {
        return L10n.format("%@ asked for it, to %@", name, detail)
      }
      return L10n.format("%@ asked for it", name)
    case let .interrupt(_, plain):
      return plain
    case .unknown:
      return L10n.string("The reason was not recorded.")
    }
  }
}

/// Turns a `pmset` interrupt token into something a person can read.
///
/// A table rather than a `switch` so it can be tested on its own, and so an unmatched
/// token is visible instead of collapsing into a generic string.
enum WakeReasonDictionary {
  /// Ordered: the first match wins, so specific tokens precede general ones.
  static let entries: [(needle: String, plain: String)] = [
    ("lid", "Opening the lid"),
    ("HID", "You — keyboard, trackpad or mouse"),
    ("Multitouch", "You — keyboard, trackpad or mouse"),
    ("keyboard", "You — keyboard, trackpad or mouse"),
    ("TRACKPAD", "You — keyboard, trackpad or mouse"),
    ("SleepService", "A scheduled background task"),
    ("Maintenance", "A scheduled background task"),
    ("rtc", "A scheduled background task"),
    ("UserActivity", "Activity on this Mac"),
    ("wifibt", "The network or a Bluetooth device"),
    ("bluetooth", "A Bluetooth device"),
    ("Wifi", "The network"),
    ("Network", "The network"),
    ("EC.", "The power controller"),
    ("PMU", "The power controller"),
    ("USB", "Something plugged in"),
    ("Thunderbolt", "Something plugged in"),
    ("ACPI", "The power controller"),
  ]

  /// The plain reading, or `nil` when the token is not recognized. `nil` is deliberate:
  /// the caller shows the raw token rather than inventing a cause.
  static func plainLanguage(for token: String) -> String? {
    for entry in entries where token.localizedCaseInsensitiveContains(entry.needle) {
      return L10n.string(entry.plain)
    }
    return nil
  }

  static func cause(forInterrupt token: String) -> WakeCause {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .unknown }
    if let plain = plainLanguage(for: trimmed) {
      return .interrupt(token: trimmed, plain: plain)
    }
    // Unrecognized: say what was recorded rather than pretending to know.
    return .interrupt(token: trimmed, plain: L10n.format("Woken by %@", trimmed))
  }
}

// MARK: - What is holding the Mac awake

/// One power assertion currently held by a process.
struct SleepAssertion: Identifiable, Equatable {
  let pid: Int32
  let process: String
  /// `PreventUserIdleSystemSleep`, `NoDisplaySleepAssertion`, …
  let type: String
  /// The name the holder gave it.
  let reason: String
  /// `pmset`'s own human sentence, when it supplies one.
  let localized: String?
  let heldSeconds: Int

  var id: String { "\(pid)|\(type)|\(reason)" }

  /// Assertions that stop the Mac sleeping, as opposed to only the display.
  var preventsSystemSleep: Bool {
    type.contains("PreventUserIdleSystemSleep") || type.contains("PreventSystemSleep")
  }

  var preventsDisplaySleep: Bool {
    type.contains("DisplaySleep") || type.contains("PreventUserIdleDisplaySleep")
  }

  /// This app's own Keep Awake action, so it is never reported as someone else's doing.
  var isMenuCue: Bool {
    reason.localizedCaseInsensitiveContains(ProductBrand.displayName)
  }

  var heldDescription: String {
    let hours = heldSeconds / 3_600
    let minutes = (heldSeconds % 3_600) / 60
    if hours > 0 { return L10n.format("%dh %dm", hours, minutes) }
    if minutes > 0 { return L10n.format("%dm", minutes) }
    return L10n.format("%ds", heldSeconds)
  }
}

// MARK: - Parsing

enum PowerAttributionParser {

  // MARK: Wake Requests

  /// Parses one `Wake Requests` line, which holds many bracketed requests.
  ///
  /// ```
  /// 2026-07-27 17:51:13 -0700 Wake Requests	[process=mDNSResponder request=Maintenance
  ///   deltaSecs=7198 wakeAt=2026-07-27 19:51:11 info="upkeep wake"] [*process=dasd …]
  /// ```
  static func parseScheduledWakes(_ text: String) -> [ScheduledWake] {
    let lineFormatter = DateFormatter()
    lineFormatter.locale = Locale(identifier: "en_US_POSIX")
    lineFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    var result: [ScheduledWake] = []
    for line in text.split(whereSeparator: \.isNewline).map(String.init) {
      guard line.count > 26, line.dropFirst(26).hasPrefix("Wake Requests") else { continue }
      guard let loggedAt = lineFormatter.date(from: String(line.prefix(25))) else { continue }
      // `wakeAt` carries no offset of its own; it is in the same zone as the line.
      let zone = String(line.dropFirst(20).prefix(5))

      for group in bracketedGroups(in: line) {
        let isWinning = group.hasPrefix("*")
        let body = isWinning ? String(group.dropFirst()) : group
        guard let process = field("process", in: body), !process.isEmpty else { continue }
        guard let wakeAtText = field("wakeAt", in: body),
          let wakeAt = lineFormatter.date(from: "\(wakeAtText) \(zone)")
        else { continue }

        result.append(
          ScheduledWake(
            loggedAt: loggedAt,
            wakeAt: wakeAt,
            process: process,
            request: field("request", in: body) ?? "",
            info: quotedField("info", in: body),
            isWinning: isWinning
          ))
      }
    }
    return result
  }

  /// Splits `[a] [b] [c]` without a regex, because `info="…"` can itself contain
  /// brackets.
  private static func bracketedGroups(in line: String) -> [String] {
    var groups: [String] = []
    var current = ""
    var depth = 0
    var inQuotes = false
    for character in line {
      if character == "\"" { inQuotes.toggle() }
      if character == "[", !inQuotes {
        depth += 1
        if depth == 1 { current = ""; continue }
      }
      if character == "]", !inQuotes {
        depth -= 1
        if depth == 0 { groups.append(current); continue }
      }
      if depth > 0 { current.append(character) }
    }
    return groups
  }

  /// `key=value` up to the next space. Values with spaces use `quotedField`.
  private static func field(_ key: String, in body: String) -> String? {
    guard let range = body.range(of: "\(key)=") else { return nil }
    let rest = body[range.upperBound...]
    if key == "wakeAt" {
      // "2026-07-27 19:51:11" — a date, so it spans one space.
      return String(rest.prefix(19))
    }
    return String(rest.prefix { !$0.isWhitespace })
  }

  private static func quotedField(_ key: String, in body: String) -> String? {
    guard let range = body.range(of: "\(key)=\"") else { return nil }
    let rest = body[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let value = String(rest[rest.startIndex..<end])
    return value.isEmpty ? nil : value
  }

  // MARK: Attribution

  /// How far a wake may drift from its scheduled time and still be that wake.
  static let attributionTolerance: TimeInterval = 90

  /// Attributes a wake to the request that scheduled it, when one lines up.
  ///
  /// Only the winning (`*`) request is a candidate — the others were never going to
  /// fire first. With no match inside the tolerance the interrupt token is used, and
  /// the wake stays honestly unattributed rather than being assigned to whichever
  /// process happened to be nearest.
  static func attribute(
    wakeAt: Date,
    interruptToken: String,
    scheduled: [ScheduledWake],
    tolerance: TimeInterval = attributionTolerance
  ) -> WakeCause {
    let candidate = scheduled
      .filter { $0.isWinning && abs($0.wakeAt.timeIntervalSince(wakeAt)) <= tolerance }
      .min { abs($0.wakeAt.timeIntervalSince(wakeAt)) < abs($1.wakeAt.timeIntervalSince(wakeAt)) }

    if let candidate {
      return .process(
        name: candidate.process,
        request: candidate.request,
        detail: candidate.info.map(readableInfo)
      )
    }
    return WakeReasonDictionary.cause(forInterrupt: interruptToken)
  }

  /// `com.apple.dasd:0:com.apple.MobileAccessoryUpdater.deviceIdleCheck` is not a
  /// sentence. Take the most specific segment and space out its camel case.
  static func readableInfo(_ info: String) -> String {
    let tail = info.split(separator: ":").last.map(String.init) ?? info
    let leaf = tail.split(separator: ".").last.map(String.init) ?? tail
    guard leaf.count > 2, leaf.contains(where: \.isUppercase) else { return tail }

    var words: [String] = []
    var current = ""
    for character in leaf {
      if character.isUppercase, !current.isEmpty {
        words.append(current)
        current = String(character).lowercased()
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { words.append(current) }
    return words.joined(separator: " ").lowercased()
  }

  // MARK: Assertions

  /// Parses `pmset -g assertions`.
  ///
  /// ```
  /// Listed by owning process:
  ///    pid 832(UURemote): [0x…] 89:44:59 PreventUserIdleSystemSleep named: "…"
  /// 	Details: …
  /// 	Localized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
  /// ```
  static func parseAssertions(_ text: String) -> [SleepAssertion] {
    var result: [SleepAssertion] = []
    var pending: SleepAssertion?

    func flush() {
      if let pending { result.append(pending) }
      pending = nil
    }

    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("pid "), let parsed = parseAssertionHeader(trimmed) {
        flush()
        pending = parsed
        continue
      }
      // Continuation lines are indented; `Localized=` is display-ready text.
      if let existing = pending, trimmed.hasPrefix("Localized=") {
        let localized = String(trimmed.dropFirst("Localized=".count))
          .trimmingCharacters(in: .whitespaces)
        pending = SleepAssertion(
          pid: existing.pid, process: existing.process, type: existing.type,
          reason: existing.reason, localized: localized.isEmpty ? nil : localized,
          heldSeconds: existing.heldSeconds)
        continue
      }
      // A non-indented, non-pid line ends the current block.
      if !line.hasPrefix(" ") && !line.hasPrefix("\t") { flush() }
    }
    flush()
    return result
  }

  /// `pid 832(UURemote): [0x00000045000180ca] 89:44:59 PreventUserIdleSystemSleep named: "…"`
  private static func parseAssertionHeader(_ line: String) -> SleepAssertion? {
    guard let openParen = line.firstIndex(of: "("),
      let closeParen = line[openParen...].firstIndex(of: ")"),
      let pid = Int32(
        line[line.index(line.startIndex, offsetBy: 4)..<openParen]
          .trimmingCharacters(in: .whitespaces))
    else { return nil }

    let process = String(line[line.index(after: openParen)..<closeParen])
    let rest = line[line.index(after: closeParen)...]

    // Duration is the first HH:MM:SS after the assertion id.
    guard let bracketEnd = rest.firstIndex(of: "]") else { return nil }
    let afterBracket = rest[rest.index(after: bracketEnd)...]
      .trimmingCharacters(in: .whitespaces)
    let fields = afterBracket.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count >= 2 else { return nil }

    let heldSeconds = parseDuration(String(fields[0]))
    let type = String(fields[1])
    let reason = quotedField("named", in: afterBracket)
      ?? afterBracket.range(of: "named: \"").map { range -> String in
        let tail = afterBracket[range.upperBound...]
        return String(tail.prefix { $0 != "\"" })
      } ?? ""

    return SleepAssertion(
      pid: pid, process: process, type: type, reason: reason,
      localized: nil, heldSeconds: heldSeconds)
  }

  /// `89:44:59` — hours can exceed 24, so this is not a date.
  static func parseDuration(_ text: String) -> Int {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return 0 }
    return parts[0] * 3_600 + parts[1] * 60 + parts[2]
  }
}
