import Foundation

/// What one process has been doing over a window, rather than in the instant a tab
/// happened to be open.
///
/// The live readout is a one-second `top` sample. That answers "what is hot right
/// now", which is not the question — "what has been keeping this Mac busy" needs
/// something accumulated. A daemon that wakes every 30 seconds reads 0.0 in almost
/// every instantaneous sample and yet may be the reason the fans are on.
struct ProcessEnergyRecord: Identifiable, Equatable, Codable {
  /// Grouped by name, not by pid: a process that restarts is the same program, and a
  /// pid is reused. This is the unit a person means by "what keeps running".
  let name: String
  /// Sum of the energy-impact readings seen for it.
  var totalImpact: Double
  /// How many samples it appeared in. With `sampleCount` this gives an average, and
  /// on its own it is the "how persistent is this" signal.
  var sampleCount: Int
  var firstSeen: Date
  var lastSeen: Date
  /// Highest single reading, so a brief but violent spike is still visible.
  var peakImpact: Double
  /// How many samples the window had already taken when this process first appeared.
  ///
  /// Without it, presence is measured against the whole window: a process that starts
  /// halfway through can never exceed 50%, and after a trim drops old records while
  /// the counter keeps climbing, everything drifts downward forever.
  var windowSamplesAtFirstSeen: Int = 0

  var id: String { name }

  var averageImpact: Double {
    sampleCount == 0 ? 0 : totalImpact / Double(sampleCount)
  }

  /// How much of *its own* window this process was present for.
  ///
  /// Measured from when it first appeared, not from when the history began — a daemon
  /// launched an hour ago that has been in every sample since is at 100%, which is the
  /// honest answer to "does this keep running".
  func presence(inWindowOf totalSamples: Int) -> Double {
    let observable = totalSamples - windowSamplesAtFirstSeen
    guard observable > 0 else { return sampleCount > 0 ? 1 : 0 }
    return min(1, Double(sampleCount) / Double(observable))
  }
}

/// Accumulates process energy samples into a bounded, persistable history.
///
/// A value type so the merging is testable without a filesystem; the store below owns
/// the reading and writing.
struct ProcessEnergyHistory: Equatable, Codable {
  private(set) var records: [String: ProcessEnergyRecord] = [:]
  /// How many samples the window covers, which is what makes `presence` meaningful.
  private(set) var totalSamples = 0
  private(set) var windowStart: Date?

  /// Names kept. Beyond this the least persistent are dropped: the point of the
  /// history is what *keeps* running, so a one-off is the right thing to lose.
  var maximumRecords = 200

  mutating func record(_ entries: [ProcessEnergyEntry], at date: Date) {
    guard !entries.isEmpty else { return }
    if windowStart == nil { windowStart = date }
    totalSamples += 1

    // Fold the sample by name *before* recording it. One `top` sample can hold seven
    // `node` processes; counting each as its own appearance made `sampleCount` exceed
    // the number of samples, so a multi-process app always outranked a single-process
    // daemon — which inverts the very thing this history is for.
    var folded: [String: (impact: Double, peak: Double)] = [:]
    for entry in entries {
      let key = entry.appName ?? entry.name
      var value = folded[key] ?? (0, 0)
      value.impact += entry.energyImpact
      value.peak = max(value.peak, entry.energyImpact)
      folded[key] = value
    }

    for (key, value) in folded {
      if var existing = records[key] {
        existing.totalImpact += value.impact
        existing.sampleCount += 1
        existing.lastSeen = date
        existing.peakImpact = max(existing.peakImpact, value.impact)
        records[key] = existing
      } else {
        records[key] = ProcessEnergyRecord(
          name: key,
          totalImpact: value.impact,
          sampleCount: 1,
          firstSeen: date,
          lastSeen: date,
          peakImpact: value.impact,
          // This sample is the first it was seen in, so its window starts here.
          windowSamplesAtFirstSeen: totalSamples - 1
        )
      }
    }
    prune()
  }

  /// Drops anything older than the retention window, then caps the count.
  mutating func trim(before cutoff: Date) {
    records = records.filter { $0.value.lastSeen >= cutoff }
    if let earliest = records.values.map(\.firstSeen).min() {
      windowStart = max(windowStart ?? earliest, cutoff)
    } else {
      windowStart = nil
      totalSamples = 0
    }
    prune()
  }

  private mutating func prune() {
    guard records.count > maximumRecords else { return }
    // Keep the persistent ones. Sorting by total impact alone would favour a single
    // enormous spike over something that has been running all day.
    let kept = records.values
      .sorted { lhs, rhs in
        if lhs.sampleCount != rhs.sampleCount { return lhs.sampleCount > rhs.sampleCount }
        return lhs.totalImpact > rhs.totalImpact
      }
      .prefix(maximumRecords)
    records = Dictionary(uniqueKeysWithValues: kept.map { ($0.name, $0) })
  }

  /// What has been keeping this Mac busy, most persistent first.
  func topByPersistence(limit: Int = 10) -> [ProcessEnergyRecord] {
    records.values
      .sorted { lhs, rhs in
        if lhs.sampleCount != rhs.sampleCount { return lhs.sampleCount > rhs.sampleCount }
        return lhs.totalImpact > rhs.totalImpact
      }
      .prefix(limit)
      .map { $0 }
  }

  /// What has cost the most energy over the window, most first.
  func topByEnergy(limit: Int = 10) -> [ProcessEnergyRecord] {
    records.values
      .sorted { $0.totalImpact > $1.totalImpact }
      .prefix(limit)
      .map { $0 }
  }
}

/// Reads and writes `ProcessEnergyHistory`, alongside the wake history.
final class ProcessEnergyHistoryStore {
  private struct Container: Codable {
    let version: Int
    var history: ProcessEnergyHistory
  }

  private static let currentVersion = 1

  private let fileURL: URL
  private let retentionHours: Int
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  /// Real writes, so "an unchanged save does not rewrite" can be asserted directly
  /// rather than by reading modification times, which are only second-accurate here.
  private(set) var writeCount = 0

  init(fileURL: URL, retentionHours: Int = 72) {
    self.fileURL = fileURL
    self.retentionHours = max(1, retentionHours)
    encoder.dateEncodingStrategy = .millisecondsSince1970
    // `records` is a dictionary, and dictionary key order is not stable across
    // encodes. Without this the byte comparison in `save` never matches, so the
    // skip-when-unchanged silently does nothing — which is exactly how an
    // optimization rots unnoticed.
    encoder.outputFormatting = [.sortedKeys]
    decoder.dateDecodingStrategy = .millisecondsSince1970
  }

  static func applicationStore(fileManager: FileManager = .default) -> ProcessEnergyHistoryStore {
    let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = root.appendingPathComponent("MenuCue", isDirectory: true)
    return ProcessEnergyHistoryStore(
      fileURL: directory.appendingPathComponent("process-energy-v1.json"))
  }

  func load(now: Date = Date()) throws -> ProcessEnergyHistory {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return ProcessEnergyHistory()
    }
    let container = try decoder.decode(Container.self, from: Data(contentsOf: fileURL))
    guard container.version == Self.currentVersion else {
      throw CocoaError(.coderReadCorrupt)
    }
    var history = container.history
    history.trim(before: now.addingTimeInterval(-Double(retentionHours) * 3_600))
    return history
  }

  func save(_ history: ProcessEnergyHistory) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(
      Container(version: Self.currentVersion, history: history))
    if let existing = try? Data(contentsOf: fileURL), existing == data { return }
    try data.write(to: fileURL, options: .atomic)
    writeCount += 1
  }

  func clear() throws {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
