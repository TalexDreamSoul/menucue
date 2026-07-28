import Foundation

enum NotificationRuntimeStoreError: Error, Equatable, LocalizedError {
  case applicationSupportUnavailable
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .applicationSupportUnavailable:
      return "Application Support is unavailable."
    case .unavailable(let message): return message
    }
  }
}

enum NotificationRuntimeDeliveryState: String, Codable, Equatable, Sendable {
  case pending
  case leased
  case delivered
  case terminal
}

struct NotificationRuntimeDelivery: Codable, Equatable, Sendable {
  var state: NotificationRuntimeDeliveryState = .pending
  var attempt = 1
  var nextAttemptAt: Date?
  var leaseID: String?
  var leaseExpiresAt: Date?
}

struct NotificationRuntimeEvent: Codable, Equatable, Sendable {
  let message: NotificationMessage
  let createdAt: Date
  var deliveries: [NotificationChannelKind: NotificationRuntimeDelivery]
}

struct NotificationRuntimeSnapshot: Codable, Equatable, Sendable {
  fileprivate static let currentVersion = 1

  var version = currentVersion
  var rules: [AlertRule] = []
  var runtimes: [String: AlertRuleRuntime] = [:]
  var cursors: [String: String] = [:]
  var events: [NotificationRuntimeEvent] = []
}

struct AlertSourceCursor: Codable, Equatable, Sendable {
  let key: String
  let value: String
}

struct AlertRuntimeCommit: Sendable {
  let ruleID: UUID
  let runtime: AlertRuleRuntime
  let cursor: AlertSourceCursor?
  let message: NotificationMessage?
  let channels: Set<NotificationChannelKind>

  init(
    ruleID: UUID,
    runtime: AlertRuleRuntime,
    cursor: AlertSourceCursor? = nil,
    message: NotificationMessage? = nil,
    channels: Set<NotificationChannelKind> = []
  ) {
    self.ruleID = ruleID
    self.runtime = runtime
    self.cursor = cursor
    self.message = message
    self.channels = channels
  }
}

actor NotificationRuntimeStore: NotificationOutboxClaiming {
  typealias Writer = @Sendable (Data, URL) throws -> Void

  private let fileURL: URL
  private let leaseDuration: TimeInterval
  private let maximumClaimCount: Int
  private let leaseID: @Sendable () -> String
  private let writer: Writer
  private let unavailableReason: String?
  private let encoder: JSONEncoder
  private var storage: NotificationRuntimeSnapshot

  init(
    fileURL: URL,
    leaseDuration: TimeInterval = 60,
    maximumClaimCount: Int = 32,
    leaseID: @escaping @Sendable () -> String = { UUID().uuidString },
    writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) },
    unavailableReason: String? = nil
  ) throws {
    self.fileURL = fileURL
    self.leaseDuration = max(1, leaseDuration)
    self.maximumClaimCount = max(1, maximumClaimCount)
    self.leaseID = leaseID
    self.writer = writer
    self.unavailableReason = unavailableReason

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder

    if unavailableReason != nil {
      self.storage = NotificationRuntimeSnapshot()
    } else if FileManager.default.fileExists(atPath: fileURL.path) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let decoded = try decoder.decode(
        NotificationRuntimeSnapshot.self,
        from: Data(contentsOf: fileURL)
      )
      guard decoded.version == NotificationRuntimeSnapshot.currentVersion else {
        throw CocoaError(.coderReadCorrupt)
      }
      self.storage = decoded
    } else {
      self.storage = NotificationRuntimeSnapshot()
    }
  }

  static func applicationStore(fileManager: FileManager = .default) throws
    -> NotificationRuntimeStore
  {
    guard
      let root = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      throw NotificationRuntimeStoreError.applicationSupportUnavailable
    }
    let directory = root.appendingPathComponent("MenuCue", isDirectory: true)
    return try NotificationRuntimeStore(
      fileURL: directory.appendingPathComponent("notification-runtime-v1.json"))
  }

  static func unavailable(reason: String) -> NotificationRuntimeStore {
    try! NotificationRuntimeStore(
      fileURL: URL(fileURLWithPath: "/dev/null"),
      unavailableReason: reason
    )
  }

  var isAvailable: Bool { unavailableReason == nil }

  func snapshot() -> NotificationRuntimeSnapshot { storage }

  func nextPendingDeliveryDate(now: Date) -> Date? {
    var dates: [Date] = []
    for event in storage.events {
      for delivery in event.deliveries.values {
        switch delivery.state {
        case .pending:
          dates.append(delivery.nextAttemptAt ?? now)
        case .leased:
          dates.append(delivery.leaseExpiresAt ?? now)
        case .delivered, .terminal:
          break
        }
      }
    }
    return dates.min()
  }

  func replaceRules(
    _ rules: [AlertRule],
    darkWakeBaseline: Date? = nil
  ) throws {
    var next = storage
    let ordered = rules.sorted { $0.id.uuidString < $1.id.uuidString }
    let previousByID = Dictionary(uniqueKeysWithValues: next.rules.map { ($0.id, $0) })
    next.rules = ordered

    let validIDs = Set(ordered.map { $0.id.uuidString })
    next.runtimes = next.runtimes.filter { validIDs.contains($0.key) }
    for rule in ordered {
      let previous = previousByID[rule.id]
      if let previous, resetSignature(previous) != resetSignature(rule) {
        next.runtimes[rule.id.uuidString] = AlertRuleRuntime()
      }
      let cursorKey = "event.darkWake:\(rule.id.uuidString)"
      if previous?.metricID == "event.darkWake", rule.metricID != "event.darkWake" {
        next.cursors.removeValue(forKey: cursorKey)
      }
      if rule.isEnabled,
        rule.metricID == "event.darkWake",
        let darkWakeBaseline
      {
        let wasJustEnabled =
          previous.map {
            !$0.isEnabled || $0.metricID != "event.darkWake"
          } ?? true
        if wasJustEnabled || next.cursors[cursorKey] == nil {
          let milliseconds = Int64((darkWakeBaseline.timeIntervalSince1970 * 1_000).rounded())
          next.cursors[cursorKey] = "baseline|\(milliseconds)"
          next.runtimes[rule.id.uuidString] = AlertRuleRuntime()
        }
      }
    }
    try persist(next)
    storage = next
  }

  func commit(_ transaction: AlertRuntimeCommit) throws {
    var next = storage
    next.runtimes[transaction.ruleID.uuidString] = transaction.runtime
    if let cursor = transaction.cursor, !cursor.key.isEmpty {
      next.cursors[cursor.key] = cursor.value
    }

    if let message = transaction.message,
      !transaction.channels.isEmpty,
      !next.events.contains(where: { $0.message.eventID == message.eventID })
    {
      let deliveries = Dictionary(
        uniqueKeysWithValues: transaction.channels.map {
          ($0, NotificationRuntimeDelivery())
        })
      next.events.append(
        NotificationRuntimeEvent(
          message: message,
          createdAt: message.occurredAt,
          deliveries: deliveries
        ))
      next.events.sort { lhs, rhs in
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.message.eventID < rhs.message.eventID
      }
    }

    try persist(next)
    storage = next
  }

  func claimPending(now: Date) async throws -> [NotificationOutboxClaim] {
    var next = storage
    var claims: [NotificationOutboxClaim] = []

    eventLoop: for eventIndex in next.events.indices {
      let kinds = next.events[eventIndex].deliveries.keys.sorted { $0.rawValue < $1.rawValue }
      for kind in kinds {
        guard claims.count < maximumClaimCount else { break eventLoop }
        guard var delivery = next.events[eventIndex].deliveries[kind] else { continue }
        let canClaim: Bool
        switch delivery.state {
        case .pending:
          canClaim = delivery.nextAttemptAt.map { $0 <= now } ?? true
        case .leased:
          canClaim = delivery.leaseExpiresAt.map { $0 <= now } ?? true
        case .delivered, .terminal:
          canClaim = false
        }
        guard canClaim else { continue }

        let newLeaseID = leaseID()
        guard !newLeaseID.isEmpty else { continue }
        delivery.state = .leased
        delivery.leaseID = newLeaseID
        delivery.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        next.events[eventIndex].deliveries[kind] = delivery
        claims.append(
          NotificationOutboxClaim(
            leaseID: newLeaseID,
            eventID: next.events[eventIndex].message.eventID,
            channelKind: kind,
            message: next.events[eventIndex].message,
            attempt: delivery.attempt
          ))
      }
    }

    guard !claims.isEmpty else { return [] }
    try persist(next)
    storage = next
    return claims
  }

  func acknowledge(_ outcome: NotificationDeliveryOutcome) async throws {
    guard
      let eventIndex = storage.events.firstIndex(where: {
        $0.message.eventID == outcome.eventID
      }),
      var delivery = storage.events[eventIndex].deliveries[outcome.channelKind],
      delivery.state == .leased,
      delivery.leaseID == outcome.leaseID
    else { return }

    switch outcome.status {
    case .delivered:
      delivery.state = .delivered
      delivery.nextAttemptAt = nil
    case .failed:
      delivery.state = .terminal
      delivery.nextAttemptAt = nil
    case .retryScheduled(let retryAt, let attempt):
      delivery.state = .pending
      delivery.attempt = max(delivery.attempt, attempt)
      delivery.nextAttemptAt = retryAt
    }
    delivery.leaseID = nil
    delivery.leaseExpiresAt = nil

    var next = storage
    next.events[eventIndex].deliveries[outcome.channelKind] = delivery
    try persist(next)
    storage = next
  }

  private func persist(_ snapshot: NotificationRuntimeSnapshot) throws {
    if let unavailableReason {
      throw NotificationRuntimeStoreError.unavailable(unavailableReason)
    }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writer(encoder.encode(snapshot), fileURL)
  }

  private func resetSignature(_ rule: AlertRule) -> String {
    let recoveryThreshold = rule.recoveryThreshold.map { String($0) } ?? ""
    return
      "\(rule.metricID.rawValue)|\(rule.targetID ?? "")|\(String(describing: rule.condition))|\(recoveryThreshold)"
  }
}
