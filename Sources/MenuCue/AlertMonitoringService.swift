import Foundation

actor AlertMonitoringService {
  typealias Sleep = @Sendable (TimeInterval) async throws -> Void
  typealias Delivery = @Sendable () async -> Void

  private let store: NotificationRuntimeStore
  private let providers: [AlertMetricProviderKind: any AlertMetricProviding]
  private var deviceName: @Sendable () -> String
  private var delivery: Delivery
  private let sleep: Sleep
  private let now: @Sendable () -> Date

  private var rules: [AlertRule] = []
  private var tasks: [AlertMetricProviderKind: Task<Void, Never>] = [:]
  private var isRunning = false
  private var isProcessing = false
  private var processingWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var lastErrorDescription: String?

  init(
    store: NotificationRuntimeStore,
    providers: [AlertMetricProviderKind: any AlertMetricProviding],
    deviceName: @escaping @Sendable () -> String = { Host.current().localizedName ?? "Mac" },
    delivery: @escaping Delivery = {},
    sleep: @escaping Sleep = { interval in
      try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
    },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.providers = providers
    self.deviceName = deviceName
    self.delivery = delivery
    self.sleep = sleep
    self.now = now
  }

  static func cadence(
    for rules: [AlertRule],
    provider kind: AlertMetricProviderKind
  ) -> TimeInterval? {
    rules.filter(\.isEnabled).compactMap { rule in
      guard AlertMetricCatalog.definition(for: rule.metricID)?.provider == kind else { return nil }
      return AlertMetricCatalog.definition(for: rule.metricID)?.minimumCadence
    }.min()
  }

  static func liveProviders() -> [AlertMetricProviderKind: any AlertMetricProviding] {
    let kinds = AlertMetricProviderKind.allSampledCases
    return Dictionary(
      uniqueKeysWithValues: kinds.map { kind in
        (kind, SystemAlertMetricProvider(kind: kind) as any AlertMetricProviding)
      })
  }

  var activeProviderKinds: Set<AlertMetricProviderKind> { Set(tasks.keys) }

  func setDeviceName(_ name: String) {
    deviceName = { name }
  }

  func setDeliveryHandler(_ delivery: @escaping Delivery) {
    self.delivery = delivery
  }

  func start() async {
    guard !isRunning else { return }
    isRunning = true
    var snapshot = await store.snapshot()
    do {
      try await store.replaceRules(snapshot.rules, darkWakeBaseline: now())
      snapshot = await store.snapshot()
      lastErrorDescription = nil
    } catch {
      lastErrorDescription = error.localizedDescription
    }
    rules = snapshot.rules
    reconcileTasks()
    await delivery()
  }

  func stop() {
    isRunning = false
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  func updateRules(_ rules: [AlertRule]) async throws {
    try await store.replaceRules(rules, darkWakeBaseline: now())
    self.rules = rules
    if isRunning { reconcileTasks() }
  }

  func processDarkWakeEvents(_ events: [WakeEvent]) async {
    let darkWakes = events.filter { $0.kind == .darkWake }.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
      return lhs.occurrence < rhs.occurrence
    }
    guard !darkWakes.isEmpty else { return }

    do {
      var snapshot = await store.snapshot()
      for rule in rules where rule.isEnabled && rule.metricID == "event.darkWake" {
        let key = darkWakeCursorKey(for: rule)
        guard let cursor = snapshot.cursors[key] else { continue }
        for event in darkWakes where darkWake(event, isAfter: cursor) {
          let observation = AlertMetricObservation.event(
            metricID: rule.metricID,
            sourceID: event.id,
            sampledAt: event.timestamp,
            context: [
              "event.kind": event.kind.rawValue,
              "event.reason": event.reason,
            ]
          )
          try await process([observation], candidateRules: [rule])
          snapshot.cursors[key] = event.id
        }
      }
      lastErrorDescription = nil
    } catch {
      lastErrorDescription = error.localizedDescription
    }
  }

  func refreshOnce(provider kind: AlertMetricProviderKind, at date: Date? = nil) async {
    guard let provider = providers[kind] else { return }
    let enabled = rules.filter {
      $0.isEnabled && AlertMetricCatalog.definition(for: $0.metricID)?.provider == kind
    }
    guard !enabled.isEmpty else { return }
    let requests = Set(
      enabled.map {
        AlertMetricRequest(metricID: $0.metricID, targetID: $0.targetID)
      })
    let observations = await provider.sample(requests: requests, at: date ?? now())
    do {
      try await process(observations, candidateRules: enabled)
      lastErrorDescription = nil
    } catch {
      lastErrorDescription = error.localizedDescription
    }
  }

  func process(_ observations: [AlertMetricObservation]) async throws {
    try await process(observations, candidateRules: rules.filter(\.isEnabled))
  }

  func handleSystemSleep() async {
    for provider in providers.values { await provider.resetBaselines() }
  }

  func handleSystemWake() async {
    for provider in providers.values { await provider.resetBaselines() }
    await delivery()
  }

  private func darkWakeCursorKey(for rule: AlertRule) -> String {
    "event.darkWake:\(rule.id.uuidString)"
  }

  private func darkWake(_ event: WakeEvent, isAfter cursor: String) -> Bool {
    let eventMilliseconds = Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded())
    if cursor.hasPrefix("baseline|"),
      let baseline = Int64(cursor.dropFirst("baseline|".count))
    {
      return eventMilliseconds > baseline
    }
    let components = cursor.split(separator: "|", omittingEmptySubsequences: false)
    guard components.count >= 3,
      let cursorMilliseconds = Int64(components[0]),
      let cursorOccurrence = Int(components[2])
    else { return false }
    if eventMilliseconds != cursorMilliseconds { return eventMilliseconds > cursorMilliseconds }
    return event.occurrence > cursorOccurrence
  }

  private func reconcileTasks() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    guard isRunning else { return }

    let grouped = Dictionary(grouping: rules.filter(\.isEnabled)) { rule in
      AlertMetricCatalog.definition(for: rule.metricID)?.provider
    }
    for (optionalKind, groupedRules) in grouped {
      guard let kind = optionalKind,
        kind != .darkWake,
        providers[kind] != nil
      else { continue }
      let cadence = Self.cadence(for: groupedRules, provider: kind) ?? 60
      let sleeper = sleep
      tasks[kind] = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          await self.refreshOnce(provider: kind)
          do { try await sleeper(cadence) } catch { return }
        }
      }
    }
  }

  private func process(
    _ observations: [AlertMetricObservation],
    candidateRules: [AlertRule]
  ) async throws {
    guard !observations.isEmpty else { return }
    await acquireProcessing()
    do {
      try await processSerially(observations, candidateRules: candidateRules)
      releaseProcessing()
    } catch {
      releaseProcessing()
      throw error
    }
  }

  private func processSerially(
    _ observations: [AlertMetricObservation],
    candidateRules: [AlertRule]
  ) async throws {
    var snapshot = await store.snapshot()
    var queuedDelivery = false

    for observation in observations {
      let matchingRules = candidateRules.filter {
        $0.metricID == observation.metricID && $0.targetID == observation.targetID
      }
      for rule in matchingRules {
        let previous = snapshot.runtimes[rule.id.uuidString] ?? AlertRuleRuntime()
        let evaluation = AlertRuleEngine.evaluate(
          rule: rule,
          runtime: previous,
          observation: observation
        )
        guard evaluation.runtime != previous || evaluation.transition != nil else { continue }

        var message: NotificationMessage?
        var cursor: AlertSourceCursor?
        if case .event(let sourceID) = observation.value {
          cursor = AlertSourceCursor(
            key: "\(observation.metricID.rawValue):\(rule.id.uuidString)",
            value: sourceID
          )
        }
        if let transition = evaluation.transition {
          message = try renderMessage(rule: rule, transition: transition)
          try message?.validate()
          queuedDelivery = true
        }

        try await store.commit(
          AlertRuntimeCommit(
            ruleID: rule.id,
            runtime: evaluation.runtime,
            cursor: cursor,
            message: message,
            channels: rule.channels
          ))
        snapshot.runtimes[rule.id.uuidString] = evaluation.runtime
        if let message {
          let deliveries = Dictionary(
            uniqueKeysWithValues: rule.channels.map {
              ($0, NotificationRuntimeDelivery())
            })
          snapshot.events.append(
            NotificationRuntimeEvent(
              message: message,
              createdAt: message.occurredAt,
              deliveries: deliveries
            ))
        }
      }
    }

    if queuedDelivery { await delivery() }
  }

  private func acquireProcessing() async {
    if !isProcessing {
      isProcessing = true
      return
    }
    await withCheckedContinuation { continuation in
      processingWaiters.append(continuation)
    }
  }

  private func releaseProcessing() {
    if processingWaiters.isEmpty {
      isProcessing = false
    } else {
      processingWaiters.removeFirst().resume()
    }
  }

  private func renderMessage(
    rule: AlertRule,
    transition: AlertRuleTransition
  ) throws -> NotificationMessage {
    let definition = AlertMetricCatalog.definition(for: rule.metricID)
    let state: NotificationEventState = transition.kind == .alert ? .alert : .recovery
    let values = AlertTemplateContextBuilder.values(
      rule: rule,
      observation: transition.observation,
      deviceName: deviceName(),
      state: state
    )

    let titleTemplate =
      transition.kind == .alert
      ? rule.alertTitleTemplate : rule.recoveryTitleTemplate
    let bodyTemplate =
      transition.kind == .alert
      ? rule.alertBodyTemplate : rule.recoveryBodyTemplate
    let title = try NotificationTemplateRenderer.render(titleTemplate, values: values)
    let body = try NotificationTemplateRenderer.render(bodyTemplate, values: values)

    return NotificationMessage(
      eventID: transition.eventID,
      deviceName: values["device.name"] ?? "Mac",
      ruleID: rule.id.uuidString,
      state: state,
      occurredAt: transition.occurredAt,
      title: title,
      body: body,
      metric: metricContext(
        rule: rule, observation: transition.observation,
        unit: AlertTemplateContextBuilder.unitText(definition?.unit))
    )
  }

  private func metricContext(
    rule: AlertRule,
    observation: AlertMetricObservation,
    unit: String
  ) -> NotificationMetricContext? {
    guard case .number(let value) = observation.value,
      case .numeric(_, let threshold) = rule.condition
    else { return nil }
    return NotificationMetricContext(
      id: rule.metricID.rawValue,
      value: value,
      unit: unit,
      threshold: threshold
    )
  }
}

extension AlertMetricProviderKind {
  fileprivate static let allSampledCases: [AlertMetricProviderKind] = [
    .system, .cpuDetail, .gpu, .memoryDetail, .storageDetail, .networkDetail, .thermal,
    .battery,
  ]
}
