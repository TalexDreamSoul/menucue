import Foundation

enum AlertMetricValue: Codable, Equatable, Sendable {
  case number(Double)
  case severity(Int)
  case boolean(Bool)
  case event(sourceID: String)
}

struct AlertMetricObservation: Codable, Equatable, Sendable {
  let metricID: AlertMetricID
  let targetID: String?
  let value: AlertMetricValue?
  let sampledAt: Date
  let isStale: Bool
  let context: [String: String]

  var isAvailable: Bool { value != nil && !isStale }

  static func value(
    metricID: AlertMetricID,
    targetID: String? = nil,
    value: AlertMetricValue,
    sampledAt: Date,
    context: [String: String] = [:]
  ) -> AlertMetricObservation {
    AlertMetricObservation(
      metricID: metricID,
      targetID: targetID,
      value: value,
      sampledAt: sampledAt,
      isStale: false,
      context: context
    )
  }

  static func unavailable(
    metricID: AlertMetricID,
    targetID: String? = nil,
    sampledAt: Date
  ) -> AlertMetricObservation {
    AlertMetricObservation(
      metricID: metricID,
      targetID: targetID,
      value: nil,
      sampledAt: sampledAt,
      isStale: false,
      context: [:]
    )
  }

  static func event(
    metricID: AlertMetricID,
    sourceID: String,
    sampledAt: Date,
    context: [String: String] = [:]
  ) -> AlertMetricObservation {
    value(
      metricID: metricID,
      value: .event(sourceID: sourceID),
      sampledAt: sampledAt,
      context: context
    )
  }
}

enum AlertCondition: Codable, Equatable, Sendable {
  case numeric(operator: AlertComparisonOperator, threshold: Double)
  case severity(operator: AlertComparisonOperator, threshold: Int)
  case boolean(is: Bool)
  case event
}

struct AlertRule: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var isEnabled: Bool
  var metricID: AlertMetricID
  var targetID: String?
  var condition: AlertCondition
  var alertDuration: TimeInterval
  var recoveryDuration: TimeInterval
  var recoveryThreshold: Double?
  var cooldown: TimeInterval
  var alertTitleTemplate: String
  var alertBodyTemplate: String
  var recoveryTitleTemplate: String
  var recoveryBodyTemplate: String
  var channels: Set<NotificationChannelKind>

  init(
    id: UUID = UUID(),
    name: String,
    isEnabled: Bool = true,
    metricID: AlertMetricID,
    targetID: String? = nil,
    condition: AlertCondition,
    alertDuration: TimeInterval = 0,
    recoveryDuration: TimeInterval = 0,
    recoveryThreshold: Double? = nil,
    cooldown: TimeInterval = 0,
    alertTitleTemplate: String? = nil,
    alertBodyTemplate: String? = nil,
    recoveryTitleTemplate: String? = nil,
    recoveryBodyTemplate: String? = nil,
    channels: Set<NotificationChannelKind>
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.metricID = metricID
    self.targetID = targetID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.condition = condition
    self.alertDuration = max(0, alertDuration)
    self.recoveryDuration = max(0, recoveryDuration)
    self.recoveryThreshold = recoveryThreshold
    self.cooldown = max(0, cooldown)
    self.alertTitleTemplate = alertTitleTemplate ?? "{{rule.name}}"
    self.alertBodyTemplate =
      alertBodyTemplate
      ?? L10n.string("{{device.name}} alert: {{metric.value}}")
    self.recoveryTitleTemplate =
      recoveryTitleTemplate
      ?? L10n.string("{{rule.name}} recovered")
    self.recoveryBodyTemplate =
      recoveryBodyTemplate
      ?? L10n.string("{{device.name}} recovered: {{metric.value}}")
    self.channels = channels
  }
  func limitingChannels(to enabledChannels: Set<NotificationChannelKind>) -> AlertRule {
    var copy = self
    copy.channels.formIntersection(enabledChannels)
    return copy
  }
}

struct AlertPhaseTimer: Codable, Equatable, Sendable {
  var elapsed: TimeInterval
  var lastQualifiedAt: Date?

  init(elapsed: TimeInterval = 0, lastQualifiedAt: Date? = nil) {
    self.elapsed = max(0, elapsed)
    self.lastQualifiedAt = lastQualifiedAt
  }

  mutating func advance(to date: Date) {
    if let lastQualifiedAt, date >= lastQualifiedAt {
      elapsed += date.timeIntervalSince(lastQualifiedAt)
    }
    self.lastQualifiedAt = date
  }

  mutating func pause() {
    lastQualifiedAt = nil
  }
}

enum AlertRulePhase: Codable, Equatable, Sendable {
  case inactive
  case pendingAlert(timer: AlertPhaseTimer, incidentStartedAt: Date)
  case active(incidentStartedAt: Date)
  case pendingRecovery(incidentStartedAt: Date, timer: AlertPhaseTimer)
}

struct AlertRuleRuntime: Codable, Equatable, Sendable {
  var phase: AlertRulePhase
  var cooldownUntil: Date?
  var lastSourceEventID: String?
  var sourceIdentity: String?

  init(
    phase: AlertRulePhase = .inactive,
    cooldownUntil: Date? = nil,
    lastSourceEventID: String? = nil,
    sourceIdentity: String? = nil
  ) {
    self.phase = phase
    self.cooldownUntil = cooldownUntil
    self.lastSourceEventID = lastSourceEventID
    self.sourceIdentity = sourceIdentity
  }
}

enum AlertTransitionKind: String, Codable, Equatable, Sendable {
  case alert
  case recovery
}

struct AlertRuleTransition: Codable, Equatable, Sendable {
  let kind: AlertTransitionKind
  let eventID: String
  let incidentStartedAt: Date
  let occurredAt: Date
  let observation: AlertMetricObservation
}

struct AlertRuleEvaluation: Codable, Equatable, Sendable {
  let runtime: AlertRuleRuntime
  let transition: AlertRuleTransition?
}

enum AlertRuleEngine {
  static func evaluate(
    rule: AlertRule,
    runtime original: AlertRuleRuntime,
    observation: AlertMetricObservation
  ) -> AlertRuleEvaluation {
    guard rule.isEnabled,
      rule.metricID == observation.metricID,
      rule.targetID == observation.targetID
    else {
      return AlertRuleEvaluation(runtime: original, transition: nil)
    }

    var normalized = original
    let sourceIdentity = observation.context["source.identity"]
    if let previousIdentity = normalized.sourceIdentity,
      let sourceIdentity,
      previousIdentity != sourceIdentity
    {
      normalized.phase = .inactive
      normalized.cooldownUntil = nil
    }
    if let sourceIdentity { normalized.sourceIdentity = sourceIdentity }

    if case .event = rule.condition {
      return evaluateEvent(rule: rule, runtime: normalized, observation: observation)
    }

    guard observation.isAvailable, let value = observation.value else {
      var paused = normalized
      switch paused.phase {
      case .pendingAlert(var timer, let startedAt):
        timer.pause()
        paused.phase = .pendingAlert(timer: timer, incidentStartedAt: startedAt)
      case .pendingRecovery(let startedAt, var timer):
        timer.pause()
        paused.phase = .pendingRecovery(incidentStartedAt: startedAt, timer: timer)
      case .inactive, .active:
        break
      }
      return AlertRuleEvaluation(runtime: paused, transition: nil)
    }

    let sampledAt = observation.sampledAt
    let alertMatches = matchesAlert(rule.condition, value: value)
    let recoveryMatches = matchesRecovery(rule: rule, value: value)
    var runtime = normalized

    switch runtime.phase {
    case .inactive:
      guard alertMatches, runtime.cooldownUntil.map({ sampledAt >= $0 }) ?? true else {
        return AlertRuleEvaluation(runtime: runtime, transition: nil)
      }
      runtime.cooldownUntil = nil
      if rule.alertDuration == 0 {
        runtime.phase = .active(incidentStartedAt: sampledAt)
        return result(
          rule: rule,
          runtime: runtime,
          kind: .alert,
          incidentStartedAt: sampledAt,
          observation: observation
        )
      }
      runtime.phase = .pendingAlert(
        timer: AlertPhaseTimer(lastQualifiedAt: sampledAt),
        incidentStartedAt: sampledAt
      )

    case .pendingAlert(var timer, let incidentStartedAt):
      guard alertMatches else {
        runtime.phase = .inactive
        return AlertRuleEvaluation(runtime: runtime, transition: nil)
      }
      timer.advance(to: sampledAt)
      if timer.elapsed >= rule.alertDuration {
        runtime.phase = .active(incidentStartedAt: incidentStartedAt)
        return result(
          rule: rule,
          runtime: runtime,
          kind: .alert,
          incidentStartedAt: incidentStartedAt,
          observation: observation
        )
      }
      runtime.phase = .pendingAlert(timer: timer, incidentStartedAt: incidentStartedAt)

    case .active(let incidentStartedAt):
      guard recoveryMatches else {
        return AlertRuleEvaluation(runtime: runtime, transition: nil)
      }
      if rule.recoveryDuration == 0 {
        runtime.phase = .inactive
        runtime.cooldownUntil = sampledAt.addingTimeInterval(rule.cooldown)
        return result(
          rule: rule,
          runtime: runtime,
          kind: .recovery,
          incidentStartedAt: incidentStartedAt,
          observation: observation
        )
      }
      runtime.phase = .pendingRecovery(
        incidentStartedAt: incidentStartedAt,
        timer: AlertPhaseTimer(lastQualifiedAt: sampledAt)
      )

    case .pendingRecovery(let incidentStartedAt, var timer):
      guard recoveryMatches else {
        runtime.phase = .active(incidentStartedAt: incidentStartedAt)
        return AlertRuleEvaluation(runtime: runtime, transition: nil)
      }
      timer.advance(to: sampledAt)
      if timer.elapsed >= rule.recoveryDuration {
        runtime.phase = .inactive
        runtime.cooldownUntil = sampledAt.addingTimeInterval(rule.cooldown)
        return result(
          rule: rule,
          runtime: runtime,
          kind: .recovery,
          incidentStartedAt: incidentStartedAt,
          observation: observation
        )
      }
      runtime.phase = .pendingRecovery(incidentStartedAt: incidentStartedAt, timer: timer)
    }

    return AlertRuleEvaluation(runtime: runtime, transition: nil)
  }

  private static func evaluateEvent(
    rule: AlertRule,
    runtime original: AlertRuleRuntime,
    observation: AlertMetricObservation
  ) -> AlertRuleEvaluation {
    guard observation.isAvailable,
      case .event(let sourceID) = observation.value,
      !sourceID.isEmpty,
      sourceID != original.lastSourceEventID
    else {
      return AlertRuleEvaluation(runtime: original, transition: nil)
    }
    var runtime = original
    runtime.lastSourceEventID = sourceID
    guard runtime.cooldownUntil.map({ observation.sampledAt >= $0 }) ?? true else {
      return AlertRuleEvaluation(runtime: runtime, transition: nil)
    }
    runtime.cooldownUntil = observation.sampledAt.addingTimeInterval(rule.cooldown)
    let eventID = "\(rule.id.uuidString)|alert|\(sourceID)"
    let transition = AlertRuleTransition(
      kind: .alert,
      eventID: eventID,
      incidentStartedAt: observation.sampledAt,
      occurredAt: observation.sampledAt,
      observation: observation
    )
    return AlertRuleEvaluation(runtime: runtime, transition: transition)
  }

  private static func matchesAlert(
    _ condition: AlertCondition,
    value: AlertMetricValue
  ) -> Bool {
    switch (condition, value) {
    case (.numeric(let comparison, let threshold), .number(let number)):
      return compare(number, comparison, threshold)
    case (.severity(let comparison, let threshold), .severity(let severity)):
      return compare(Double(severity), comparison, Double(threshold))
    case (.boolean(let expected), .boolean(let actual)):
      return actual == expected
    case (.event, .event):
      return true
    default:
      return false
    }
  }

  private static func matchesRecovery(rule: AlertRule, value: AlertMetricValue) -> Bool {
    switch (rule.condition, value) {
    case (.numeric(let comparison, let threshold), .number(let number)):
      let boundary = rule.recoveryThreshold ?? threshold
      switch comparison {
      case .above: return number <= boundary
      case .below: return number >= boundary
      default: return false
      }
    case (.severity(let comparison, let threshold), .severity(let severity)):
      switch comparison {
      case .atLeast: return severity < threshold
      case .atMost: return severity > threshold
      default: return false
      }
    case (.boolean(let expected), .boolean(let actual)):
      return actual != expected
    default:
      return false
    }
  }

  private static func compare(
    _ value: Double,
    _ comparison: AlertComparisonOperator,
    _ threshold: Double
  ) -> Bool {
    switch comparison {
    case .above: return value > threshold
    case .below: return value < threshold
    case .atLeast: return value >= threshold
    case .atMost: return value <= threshold
    case .equal: return value == threshold
    case .notEqual: return value != threshold
    case .occurs: return false
    }
  }

  private static func result(
    rule: AlertRule,
    runtime: AlertRuleRuntime,
    kind: AlertTransitionKind,
    incidentStartedAt: Date,
    observation: AlertMetricObservation
  ) -> AlertRuleEvaluation {
    let milliseconds = Int64((incidentStartedAt.timeIntervalSince1970 * 1_000).rounded())
    let transition = AlertRuleTransition(
      kind: kind,
      eventID: "\(rule.id.uuidString)|\(kind.rawValue)|\(milliseconds)",
      incidentStartedAt: incidentStartedAt,
      occurredAt: observation.sampledAt,
      observation: observation
    )
    return AlertRuleEvaluation(runtime: runtime, transition: transition)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
