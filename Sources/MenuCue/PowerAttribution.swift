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
    ("Notification", "A notification"),
    ("Alarm", "An alarm or timer"),
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

/// Turns a `pmset` sleep reason into something a person can read.
///
/// Separate from `WakeReasonDictionary` because a sleep is not a wake. Running the
/// sleep reasons through the wake table produced sentences that were flatly untrue:
/// `Clamshell Sleep` came out as "Woken by Clamshell Sleep", and `Maintenance Sleep`
/// matched the `Maintenance` needle and came out as "A scheduled background task" —
/// the reading for a wake the Mac had *not* just had.
enum SleepReasonDictionary {
  /// Ordered: the first match wins, so specific reasons precede general ones.
  static let entries: [(needle: String, plain: String)] = [
    ("Clamshell", "You closed the lid"),
    ("Sleep Service", "Back to sleep after background work"),
    ("Maintenance", "Back to sleep after background work"),
    ("Low Power", "Went to sleep to save power"),
    ("Idle", "Went to sleep after being idle"),
    ("Software Sleep", "An app asked it to sleep"),
    ("Menu Item", "You asked it to sleep"),
  ]

  /// The plain reading, or `nil` when the reason is not recognized.
  static func plainLanguage(for reason: String) -> String? {
    for entry in entries where reason.localizedCaseInsensitiveContains(entry.needle) {
      return L10n.string(entry.plain)
    }
    return nil
  }

  /// One sentence for a sleep row. An unrecognized reason is shown verbatim rather
  /// than dressed up as something the parser does not actually know.
  static func sentence(for reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return L10n.string("Went to sleep") }
    if let plain = plainLanguage(for: trimmed) { return plain }
    return L10n.format("Went to sleep — %@", trimmed)
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
  /// `pmset`'s own handle for this assertion — the `[0x0004a2cf00018173]` field.
  ///
  /// Identity, not decoration. One process holds several assertions of the same type
  /// with the same name as a matter of course: `coreaudiod` takes one per audio
  /// client, so on this Mac `pid 413(coreaudiod)` appears twice with an identical
  /// `PreventUserIdleSystemSleep` / `com.apple.audio.…preventuseridlesleep` pair.
  /// Keying on pid + type + reason collapsed those two into one `id`, which is
  /// undefined behaviour in a SwiftUI `ForEach` — measured as 8 blockers sharing 7
  /// ids on a live read.
  let handle: String

  var id: String {
    handle.isEmpty ? "\(pid)|\(type)|\(reason)|\(heldSeconds)" : handle
  }

  /// Assertions that stop the Mac sleeping, as opposed to only the display.
  var preventsSystemSleep: Bool {
    type.contains("PreventUserIdleSystemSleep") || type.contains("PreventSystemSleep")
  }

  var preventsDisplaySleep: Bool {
    type.contains("DisplaySleep") || type.contains("PreventUserIdleDisplaySleep")
  }

  /// Whether this assertion is the one this app's Keep Awake action is holding.
  ///
  /// Matched by pid, not by text. `caffeinate`'s assertion reason is the fixed string
  /// "caffeinate command-line tool" — it never mentions who started it — so a name
  /// match was always false and the app reported its own assertion as some
  /// unidentified program keeping the Mac awake.
  func isOwned(byPID pid: Int32?) -> Bool {
    guard let pid else { return false }
    return self.pid == pid
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
  /// Byte-level filter for the `Wake Requests` domain, so one streaming pass can keep
  /// both these lines and the wake events without allocating a String per line.
  static func isWakeRequestLine(_ line: Data.SubSequence) -> Bool {
    let prefixLength = 26
    guard line.count > prefixLength else { return false }
    let domain = line[line.index(line.startIndex, offsetBy: prefixLength)...]
    return domain.starts(with: wakeRequestsPrefix)
  }

  private static let wakeRequestsPrefix = Array("Wake Requests".utf8)

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

  /// The one sentence for one row of history — the only thing either surface should
  /// call, so the popover and the Dashboard cannot drift apart.
  ///
  /// A `Sleep` row is never attributed. `Wake Requests` is logged a second or two
  /// *after* the machine sleeps, so its winning request routinely lands inside the
  /// attribution tolerance of the sleep that preceded it: on this Mac a real sleep at
  /// 17:51:11 rendered as "dasd asked for it, to next scheduled timeline refresh"
  /// because a wake had been scheduled for 17:50:34. Attributing only wakes makes
  /// that impossible rather than merely unlikely.
  static func sentence(for event: WakeEvent, scheduled: [ScheduledWake]) -> String {
    guard event.kind != .sleep else {
      return SleepReasonDictionary.sentence(for: event.reason)
    }
    return attribute(
      wakeAt: event.timestamp, interruptToken: event.reason, scheduled: scheduled
    ).sentence
  }

  /// `com.apple.dasd:0:com.apple.MobileAccessoryUpdater.deviceIdleCheck` is not a
  /// sentence. Take the most specific segment and space out its camel case.
  static func readableInfo(_ info: String) -> String {
    let tail = info.split(separator: ":").last.map(String.init) ?? info
    let leaf = tail.split(separator: ".").last.map(String.init) ?? tail
    // An all-lowercase leaf like `heartbeat` needs no splitting, but it is still the
    // leaf: returning `tail` here printed the whole `com.apple.searchd.heartbeat`.
    guard leaf.count > 2, leaf.contains(where: \.isUppercase) else { return leaf }

    // Break at camel-case boundaries only. Breaking at *every* capital shredded runs
    // of them: `DHCP lease renewal` came out of a live read as `d h c p lease renewal`,
    // and `user-invisible-Weekly Usage Report,625` came out with doubled spaces.
    let characters = Array(leaf)
    var words: [String] = []
    var current = ""
    for (index, character) in characters.enumerated() {
      let previous = index > 0 ? characters[index - 1] : nil
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      // `wakeUp` → break before `U`. `HTTPServer` → break before `S`, not inside
      // `HTTP`. `DHCP lease` → no break at all.
      let startsWord =
        character.isUppercase && !current.isEmpty
        && ((previous?.isLowercase ?? false) || (previous?.isNumber ?? false)
          || ((previous?.isUppercase ?? false) && (next?.isLowercase ?? false)))
      if startsWord {
        words.append(current)
        current = String(character)
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
          heldSeconds: existing.heldSeconds, handle: existing.handle)
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
    let handle = rest.firstIndex(of: "[").map { open in
      String(rest[rest.index(after: open)..<bracketEnd])
    } ?? ""
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
      localized: nil, heldSeconds: heldSeconds, handle: handle)
  }

  /// `89:44:59` — hours can exceed 24, so this is not a date.
  static func parseDuration(_ text: String) -> Int {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return 0 }
    return parts[0] * 3_600 + parts[1] * 60 + parts[2]
  }
}
