import Foundation

struct WakeHistorySnapshot: Equatable {
  let events: [WakeEvent]
  let dailySummaries: [WakeDailySummary]
}

final class WakeHistoryStore {
  private struct Container: Codable {
    let version: Int
    var events: [WakeEvent]
    var clearedAt: Date?
  }

  /// What `write` stamps. Anything older is migrated on read rather than being
  /// reinterpreted — the previous code accepted 1 or 2 and then wrote 2 regardless,
  /// so a v1 file was silently treated as v2 with no migration step at all.
  private static let currentVersion = 2

  private let fileURL: URL
  private let retentionDays: Int
  private let maxRecords: Int
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  /// How many times the file has actually been rewritten.
  ///
  /// Exposed because "an unchanged merge does not rewrite" cannot be asserted from
  /// the outside: file modification times are only reliable to the second here, so a
  /// test comparing them is measuring the clock rather than the behaviour.
  private(set) var writeCount = 0

  init(fileURL: URL, retentionDays: Int = 30, maxRecords: Int = 100_000) {
    self.fileURL = fileURL
    self.retentionDays = max(1, retentionDays)
    self.maxRecords = max(1, maxRecords)
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    decoder.dateDecodingStrategy = .millisecondsSince1970
  }

  static func applicationStore(fileManager: FileManager = .default) -> WakeHistoryStore {
    let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = root.appendingPathComponent("MenuCue", isDirectory: true)
    return WakeHistoryStore(fileURL: directory.appendingPathComponent("wake-history-v1.json"))
  }

  func load(now: Date = Date(), calendar: Calendar = .current) throws -> WakeHistorySnapshot {
    let retained = retainedEvents(try readContainer().events, now: now)
    return WakeHistorySnapshot(events: retained, dailySummaries: summaries(retained, calendar: calendar))
  }

  func merge(
    _ incoming: [WakeEvent],
    now: Date = Date(),
    calendar: Calendar = .current
  ) throws {
    let container = try readContainer()
    var byID = Dictionary(uniqueKeysWithValues: container.events.map { ($0.id, $0) })
    for event in incoming where container.clearedAt.map({ event.timestamp > $0 }) ?? true {
      byID[event.id] = event
    }
    let retained = retainedEvents(Array(byID.values), now: now)
    try write(retained, clearedAt: container.clearedAt)
  }

  func clear(now: Date = Date()) throws {
    try write([], clearedAt: now)
  }

  private func readContainer() throws -> Container {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return Container(version: 2, events: [], clearedAt: nil)
    }
    let data = try Data(contentsOf: fileURL)
    let container = try decoder.decode(Container.self, from: data)
    switch container.version {
    case Self.currentVersion:
      return container
    case 1:
      return migrateFromVersion1(container)
    default:
      throw CocoaError(.coderReadCorrupt)
    }
  }

  /// v1 predates scheduled wakes being split out, so it can hold records whose reason
  /// is a whole `[process=… deltaSecs=…]` blob — the fabricated ones. They are dropped
  /// rather than migrated, because there is nothing to recover: they describe wakes
  /// that were planned, not wakes that happened.
  private func migrateFromVersion1(_ container: Container) -> Container {
    var migrated = container
    migrated.events = container.events.filter { !$0.reason.contains("process=") }
    return Container(
      version: Self.currentVersion, events: migrated.events, clearedAt: container.clearedAt)
  }

  private func retainedEvents(_ events: [WakeEvent], now: Date) -> [WakeEvent] {
    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
    let ordered = events.filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) }
      .sorted { lhs, rhs in
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.occurrence != rhs.occurrence { return lhs.occurrence < rhs.occurrence }
        return lhs.id < rhs.id
      }
    return Array(ordered.suffix(maxRecords))
  }

  private func summaries(_ events: [WakeEvent], calendar: Calendar) -> [WakeDailySummary] {
    var counts: [Date: (sleep: Int, dark: Int, wake: Int)] = [:]
    for event in events {
      // Bucket by the offset recorded with the event, not by wherever the user is
      // now. Using `Calendar.current` here re-dated every historical night the moment
      // someone changed time zone.
      let day = startOfDay(for: event, calendar: calendar)
      var value = counts[day, default: (0, 0, 0)]
      switch event.kind {
      case .sleep: value.sleep += 1
      case .darkWake: value.dark += 1
      case .wake: value.wake += 1
      }
      counts[day] = value
    }
    return counts.map { day, value in
      WakeDailySummary(
        day: day,
        sleepCount: value.sleep,
        darkWakeCount: value.dark,
        userWakeCount: value.wake)
    }.sorted { $0.day < $1.day }
  }

  private func startOfDay(for event: WakeEvent, calendar: Calendar) -> Date {
    guard let offset = event.utcOffsetSeconds,
      let zone = TimeZone(secondsFromGMT: offset)
    else { return calendar.startOfDay(for: event.timestamp) }
    var recorded = calendar
    recorded.timeZone = zone
    return recorded.startOfDay(for: event.timestamp)
  }

  private func write(_ events: [WakeEvent], clearedAt: Date?) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(
      Container(version: Self.currentVersion, events: events, clearedAt: clearedAt))
    // Skip the write when nothing changed. Every refresh used to decode and re-encode
    // the whole file, which does not scale with the record counts the old fabricated
    // events produced.
    if let existing = try? Data(contentsOf: fileURL), existing == data { return }
    try data.write(to: fileURL, options: .atomic)
    writeCount += 1
  }
}
