import XCTest

@testable import MenuCue

final class AlertMetricCatalogTests: XCTestCase {
  func testCatalogMatchesReviewedIncludedInventoryLiterally() {
    let expected: Set<String> = [
      "cpu.total.busy", "cpu.total.user", "cpu.total.system", "cpu.total.idle",
      "cpu.core.busy", "cpu.load.1m", "cpu.load.5m", "cpu.load.15m",
      "gpu.device.utilization", "gpu.renderer.utilization", "gpu.memory.inUse",
      "memory.used", "memory.used.percent", "memory.app", "memory.wired",
      "memory.compressed", "memory.cached", "memory.pressure", "swap.used",
      "swap.used.percent", "storage.volume.used", "storage.volume.free",
      "storage.volume.usedPercent", "disk.read.rate", "disk.write.rate",
      "disk.read.operations", "disk.write.operations", "network.download.rate",
      "network.upload.rate", "network.interface.downloadRate",
      "network.interface.uploadRate", "sensor.cpu.temperature",
      "sensor.thermal.temperature", "fan.speed", "fan.load", "battery.level",
      "battery.flow.watts", "battery.flow.percentPerHour", "battery.charging",
      "power.onAC", "event.darkWake",
    ]

    XCTAssertEqual(Set(AlertMetricCatalog.all.map(\.id.rawValue)), expected)
    XCTAssertEqual(AlertMetricCatalog.all.count, expected.count)
  }

  func testCatalogKeepsExcludedMetricsOut() {
    let ids = Set(AlertMetricCatalog.all.map(\.id.rawValue))
    let excluded = [
      "cpu.total.nice", "memory.total", "swap.total", "storage.volume.total",
      "fan.minimum", "fan.maximum", "disk.read.total", "disk.write.total",
      "battery.timeRemaining", "process.memory", "wake.count",
    ]

    XCTAssertTrue(excluded.allSatisfy { !ids.contains($0) })
  }

  func testThermalIdentityIsStableAndNotDerivedFromLocalizedLabel() {
    let english = ThermalReading(
      sensorID: "hid:performance-cluster", label: "P-cluster", celsius: 71,
      kind: .performanceCluster)
    let chinese = ThermalReading(
      sensorID: "hid:performance-cluster", label: "性能核心簇", celsius: 71,
      kind: .performanceCluster)
    let ambient = ThermalReading(
      sensorID: "smc:TA0P", label: "Ambient", celsius: 31, kind: .other)
    let proximity = ThermalReading(
      sensorID: "smc:TC0P", label: "CPU proximity", celsius: 42, kind: .other)

    XCTAssertEqual(english.id, chinese.id)
    XCTAssertNotEqual(ambient.id, proximity.id)
    XCTAssertTrue(english.id.hasPrefix("hid:"))
    XCTAssertTrue(ambient.id.hasPrefix("smc:"))
  }
}

final class NotificationTemplateRendererTests: XCTestCase {
  func testParserAllowsKnownRepeatedVariablesAndUnicode() throws {
    let template = try NotificationTemplateRenderer.parse(
      "{{device.name}}：{{metric.value}}{{metric.unit}} / {{metric.value}}")

    let rendered = try NotificationTemplateRenderer.render(
      template,
      values: [
        "device.name": "工作室 Mac",
        "metric.value": "91",
        "metric.unit": "%",
      ]
    )

    XCTAssertEqual(rendered, "工作室 Mac：91% / 91")
  }

  func testParserRejectsUnknownAndMalformedVariables() {
    XCTAssertThrowsError(try NotificationTemplateRenderer.parse("{{secret.token}}"))
    XCTAssertThrowsError(try NotificationTemplateRenderer.parse("{{metric.value"))
    XCTAssertThrowsError(try NotificationTemplateRenderer.parse("{{ metric.value }}"))
  }

  func testMissingOptionalContextRendersEmptyAndOutputIsBounded() throws {
    let template = try NotificationTemplateRenderer.parse("Reason: {{event.reason}}")
    XCTAssertEqual(try NotificationTemplateRenderer.render(template, values: [:]), "Reason: ")

    let oversized = try NotificationTemplateRenderer.parse(String(repeating: "a", count: 4_001))
    XCTAssertThrowsError(try NotificationTemplateRenderer.render(oversized, values: [:]))
  }

  func testSharedContextLocalizesMetricAndFormatsFractionThreshold() {
    let rule = AlertRule(
      name: "CPU high", metricID: "cpu.total.busy",
      condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark])
    let observation = AlertMetricObservation.value(
      metricID: rule.metricID,
      value: .number(0.92),
      sampledAt: Date(timeIntervalSince1970: 10)
    )

    let values = AlertTemplateContextBuilder.values(
      rule: rule, observation: observation, deviceName: "Work Mac", state: .alert)

    XCTAssertEqual(values["device.name"], "Work Mac")
    XCTAssertEqual(values["metric.name"], L10n.string("cpu.total.busy"))
    XCTAssertEqual(values["metric.value"], "92%")
    XCTAssertEqual(values["metric.threshold"], "90%")
  }

  func testDefaultTemplatesCoverAlertAndRecovery() throws {
    let context = [
      "device.name": "Studio Mac",
      "rule.name": "CPU hot",
      "metric.value": "92%",
    ]
    let alert = try NotificationTemplateRenderer.render(
      NotificationTemplateRenderer.defaultAlertBody, values: context)
    let recovery = try NotificationTemplateRenderer.render(
      NotificationTemplateRenderer.defaultRecoveryBody, values: context)

    XCTAssertTrue(alert.contains("Studio Mac"))
    XCTAssertTrue(alert.contains("92%"))
    XCTAssertNotEqual(alert, recovery)
  }
}

final class AlertRuleEngineTests: XCTestCase {
  private let ruleID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  func testNumericRuleUsesStrictBoundaryAndSustainedDuration() {
    let rule = numericRule(alertDuration: 10)
    var runtime = AlertRuleRuntime()

    runtime = evaluate(rule, runtime, value: .number(0.8), at: 0).runtime
    XCTAssertEqual(runtime.phase, .inactive)

    runtime = evaluate(rule, runtime, value: .number(0.9), at: 1).runtime
    XCTAssertEqual(runtime.phase, .inactive)

    runtime = evaluate(rule, runtime, value: .number(0.91), at: 2).runtime
    XCTAssertTrue(runtime.phase.isPendingAlert)

    let almost = evaluate(rule, runtime, value: .number(0.92), at: 11)
    XCTAssertNil(almost.transition)

    let reached = evaluate(rule, almost.runtime, value: .number(0.93), at: 12)
    XCTAssertEqual(reached.transition?.kind, .alert)
    XCTAssertTrue(reached.runtime.phase.isActive)
  }

  func testUnavailableSamplePausesPendingDuration() {
    let rule = numericRule(alertDuration: 10)
    var result = evaluate(rule, AlertRuleRuntime(), value: .number(0.95), at: 0)
    result = AlertRuleEngine.evaluate(
      rule: rule,
      runtime: result.runtime,
      observation: .unavailable(metricID: rule.metricID, sampledAt: date(100))
    )
    result = evaluate(rule, result.runtime, value: .number(0.95), at: 101)
    XCTAssertNil(result.transition)
    result = evaluate(rule, result.runtime, value: .number(0.95), at: 110)
    XCTAssertNil(result.transition)
    result = evaluate(rule, result.runtime, value: .number(0.95), at: 111)
    XCTAssertEqual(result.transition?.kind, .alert)
  }

  func testRecoveryHysteresisInterruptionAndCooldown() {
    let rule = numericRule(
      alertDuration: 0, recoveryDuration: 5, recoveryThreshold: 0.7, cooldown: 20)
    var result = evaluate(rule, AlertRuleRuntime(), value: .number(0.95), at: 0)
    XCTAssertEqual(result.transition?.kind, .alert)

    result = evaluate(rule, result.runtime, value: .number(0.75), at: 2)
    XCTAssertTrue(result.runtime.phase.isActive)

    result = evaluate(rule, result.runtime, value: .number(0.65), at: 3)
    XCTAssertTrue(result.runtime.phase.isPendingRecovery)
    result = evaluate(rule, result.runtime, value: .number(0.8), at: 5)
    XCTAssertTrue(result.runtime.phase.isActive)

    result = evaluate(rule, result.runtime, value: .number(0.65), at: 6)
    result = evaluate(rule, result.runtime, value: .number(0.65), at: 11)
    XCTAssertEqual(result.transition?.kind, .recovery)

    result = evaluate(rule, result.runtime, value: .number(0.99), at: 20)
    XCTAssertNil(result.transition)
    XCTAssertEqual(result.runtime.phase, .inactive)
    result = evaluate(rule, result.runtime, value: .number(0.99), at: 31)
    XCTAssertEqual(result.transition?.kind, .alert)
  }

  func testBooleanSeverityAndEventRulesUseTypedPaths() {
    let boolRule = AlertRule(
      id: ruleID, name: "Battery charging", metricID: "battery.charging",
      condition: .boolean(is: false), channels: [.bark])
    let boolResult = AlertRuleEngine.evaluate(
      rule: boolRule, runtime: AlertRuleRuntime(),
      observation: .value(
        metricID: boolRule.metricID, value: .boolean(false), sampledAt: date(1)))
    XCTAssertEqual(boolResult.transition?.kind, .alert)

    let severityRule = AlertRule(
      id: ruleID, name: "Memory pressure", metricID: "memory.pressure",
      condition: .severity(operator: .atLeast, threshold: 2), channels: [.bark])
    let severityResult = AlertRuleEngine.evaluate(
      rule: severityRule, runtime: AlertRuleRuntime(),
      observation: .value(
        metricID: severityRule.metricID, value: .severity(2), sampledAt: date(1)))
    XCTAssertEqual(severityResult.transition?.kind, .alert)

    let eventRule = AlertRule(
      id: ruleID, name: "Dark wake", metricID: "event.darkWake",
      condition: .event, channels: [.bark])
    let event = AlertMetricObservation.event(
      metricID: eventRule.metricID, sourceID: "wake-42", sampledAt: date(5))
    let first = AlertRuleEngine.evaluate(
      rule: eventRule, runtime: AlertRuleRuntime(), observation: event)
    let replay = AlertRuleEngine.evaluate(
      rule: eventRule, runtime: first.runtime, observation: event)
    XCTAssertEqual(first.transition?.kind, .alert)
    XCTAssertNil(replay.transition)
    XCTAssertTrue(first.transition?.eventID.contains("wake-42") == true)
  }

  func testEventRuleHonorsCooldownAndConsumesSuppressedSourceIDs() {
    let rule = AlertRule(
      id: ruleID, name: "Dark wake", metricID: "event.darkWake",
      condition: .event, cooldown: 60, channels: [.bark])
    let first = AlertRuleEngine.evaluate(
      rule: rule, runtime: AlertRuleRuntime(),
      observation: .event(metricID: rule.metricID, sourceID: "wake-1", sampledAt: date(0)))
    let suppressed = AlertRuleEngine.evaluate(
      rule: rule, runtime: first.runtime,
      observation: .event(metricID: rule.metricID, sourceID: "wake-2", sampledAt: date(30)))
    let afterCooldown = AlertRuleEngine.evaluate(
      rule: rule, runtime: suppressed.runtime,
      observation: .event(metricID: rule.metricID, sourceID: "wake-3", sampledAt: date(60)))

    XCTAssertEqual(first.transition?.kind, .alert)
    XCTAssertNil(suppressed.transition)
    XCTAssertEqual(suppressed.runtime.lastSourceEventID, "wake-2")
    XCTAssertEqual(afterCooldown.transition?.kind, .alert)
  }

  func testPrimarySourceIdentityChangeResetsAnActiveRule() {
    let rule = numericRule(alertDuration: 0)
    let first = AlertRuleEngine.evaluate(
      rule: rule,
      runtime: AlertRuleRuntime(),
      observation: .value(
        metricID: rule.metricID, value: .number(0.95), sampledAt: date(1),
        context: ["source.identity": "en0"])
    )
    let changed = AlertRuleEngine.evaluate(
      rule: rule,
      runtime: first.runtime,
      observation: .unavailable(metricID: rule.metricID, sampledAt: date(2))
    )
    let changedSource = AlertRuleEngine.evaluate(
      rule: rule,
      runtime: changed.runtime,
      observation: .value(
        metricID: rule.metricID, value: .number(0.5), sampledAt: date(3),
        context: ["source.identity": "en1"])
    )

    XCTAssertEqual(changedSource.runtime.phase, .inactive)
    XCTAssertEqual(changedSource.runtime.sourceIdentity, "en1")
  }

  func testRuntimeRoundTripPreservesPendingStateAcrossRelaunch() throws {
    let runtime = evaluate(
      numericRule(alertDuration: 10), AlertRuleRuntime(), value: .number(0.95), at: 3
    ).runtime
    let data = try JSONEncoder().encode(runtime)
    XCTAssertEqual(try JSONDecoder().decode(AlertRuleRuntime.self, from: data), runtime)
  }

  private func numericRule(
    alertDuration: TimeInterval,
    recoveryDuration: TimeInterval = 0,
    recoveryThreshold: Double? = nil,
    cooldown: TimeInterval = 0
  ) -> AlertRule {
    AlertRule(
      id: ruleID,
      name: "CPU high",
      metricID: "cpu.total.busy",
      condition: .numeric(operator: .above, threshold: 0.9),
      alertDuration: alertDuration,
      recoveryDuration: recoveryDuration,
      recoveryThreshold: recoveryThreshold,
      cooldown: cooldown,
      channels: [.bark]
    )
  }

  private func evaluate(
    _ rule: AlertRule,
    _ runtime: AlertRuleRuntime,
    value: AlertMetricValue,
    at seconds: TimeInterval
  ) -> AlertRuleEvaluation {
    AlertRuleEngine.evaluate(
      rule: rule,
      runtime: runtime,
      observation: .value(metricID: rule.metricID, value: value, sampledAt: date(seconds))
    )
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }
}

final class NotificationRuntimeStoreTests: XCTestCase {
  func testCommitPersistsRuntimeCursorRenderedMessageAndChannelSnapshotAtomically() async throws {
    let url = temporaryURL()
    let store = try NotificationRuntimeStore(fileURL: url, leaseID: { "lease-1" })
    let rule = rule()
    let runtime = AlertRuleRuntime(phase: .active(incidentStartedAt: date(10)))
    let message = NotificationMessage(
      eventID: "event-1",
      deviceName: "Studio Mac",
      ruleID: rule.id.uuidString,
      state: .alert,
      occurredAt: date(12),
      title: "CPU high",
      body: "CPU reached 95%",
      metric: NotificationMetricContext(
        id: "cpu.total.busy", value: 0.95, unit: "%", threshold: 0.9)
    )

    try await store.commit(
      AlertRuntimeCommit(
        ruleID: rule.id,
        runtime: runtime,
        cursor: AlertSourceCursor(key: "dark-wake", value: "wake-1"),
        message: message,
        channels: [.bark, .telegram]
      ))

    let reloaded = try NotificationRuntimeStore(fileURL: url, leaseID: { "lease-2" })
    let snapshot = await reloaded.snapshot()
    XCTAssertEqual(snapshot.runtimes[rule.id.uuidString], runtime)
    XCTAssertEqual(snapshot.cursors["dark-wake"], "wake-1")
    XCTAssertEqual(snapshot.events.first?.message, message)
    XCTAssertEqual(
      Set(snapshot.events.first.map { Array($0.deliveries.keys) } ?? []),
      [.bark, .telegram]
    )
  }

  func testUnavailableRuntimeDoesNotReplaceUnreadablePersistentFile() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: url)
    XCTAssertThrowsError(try NotificationRuntimeStore(fileURL: url))

    let unavailable = NotificationRuntimeStore.unavailable(reason: "Unavailable")
    let isAvailable = await unavailable.isAvailable
    XCTAssertFalse(isAvailable)
    do {
      try await unavailable.replaceRules([])
      XCTFail("Expected unavailable store")
    } catch let error as NotificationRuntimeStoreError {
      XCTAssertEqual(error, .unavailable("Unavailable"))
    }
    XCTAssertEqual(try Data(contentsOf: url), corrupt)
  }

  func testClaimPersistsLeaseAndExpiredClaimGetsNewIdentity() async throws {
    let url = temporaryURL()
    let leases = LockedStringSequence(["lease-old", "lease-new"])
    let store = try NotificationRuntimeStore(
      fileURL: url, leaseDuration: 10, leaseID: { leases.next() })
    try await store.commit(commit(eventID: "event-1", channels: [.bark]))

    let first = try await store.claimPending(now: date(0))
    XCTAssertEqual(first.first?.leaseID, "lease-old")
    let stillLeased = try await store.claimPending(now: date(5))
    XCTAssertTrue(stillLeased.isEmpty)

    let second = try await store.claimPending(now: date(11))
    XCTAssertEqual(second.first?.leaseID, "lease-new")

    try await store.acknowledge(
      NotificationDeliveryOutcome(
        leaseID: "lease-old", eventID: "event-1", channelKind: .bark, status: .delivered))
    var snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events[0].deliveries[.bark]?.state, .leased)

    try await store.acknowledge(
      NotificationDeliveryOutcome(
        leaseID: "lease-new", eventID: "event-1", channelKind: .bark, status: .delivered))
    snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events[0].deliveries[.bark]?.state, .delivered)
  }

  func testRuleReplacementAndDarkWakeBaselineShareOneAtomicWrite() async throws {
    let url = temporaryURL()
    let initial = try NotificationRuntimeStore(fileURL: url)
    let darkRule = AlertRule(
      name: "Dark wake", metricID: "event.darkWake", condition: .event, channels: [.bark])
    let failing = try NotificationRuntimeStore(
      fileURL: url,
      writer: { _, _ in throw CocoaError(.fileWriteUnknown) }
    )

    do {
      try await failing.replaceRules(
        [darkRule], darkWakeBaseline: Date(timeIntervalSince1970: 100))
      XCTFail("Expected write failure")
    } catch {}

    let snapshot = await initial.snapshot()
    XCTAssertTrue(snapshot.rules.isEmpty)
    XCTAssertTrue(snapshot.cursors.isEmpty)
  }

  func testReenablingDarkWakeRuleMovesBaselineForwardAtomically() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    var rule = AlertRule(
      name: "Dark wake", metricID: "event.darkWake", condition: .event, channels: [.bark])
    try await store.replaceRules([rule], darkWakeBaseline: date(10))
    rule.isEnabled = false
    try await store.replaceRules([rule], darkWakeBaseline: date(20))
    rule.isEnabled = true
    try await store.replaceRules([rule], darkWakeBaseline: date(30))

    let snapshot = await store.snapshot()
    XCTAssertEqual(
      snapshot.cursors["event.darkWake:\(rule.id.uuidString)"],
      "baseline|30000"
    )
    XCTAssertEqual(snapshot.runtimes[rule.id.uuidString], AlertRuleRuntime())
  }

  func testReturningToDarkWakeMetricCreatesFreshBaseline() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    var rule = AlertRule(
      name: "Rule", metricID: "event.darkWake", condition: .event, channels: [.bark])
    try await store.replaceRules([rule], darkWakeBaseline: date(10))
    rule.metricID = "cpu.total.busy"
    rule.condition = .numeric(operator: .above, threshold: 0.9)
    try await store.replaceRules([rule], darkWakeBaseline: date(20))
    var snapshot = await store.snapshot()
    XCTAssertNil(snapshot.cursors["event.darkWake:\(rule.id.uuidString)"])

    rule.metricID = "event.darkWake"
    rule.condition = .event
    try await store.replaceRules([rule], darkWakeBaseline: date(30))
    snapshot = await store.snapshot()
    XCTAssertEqual(
      snapshot.cursors["event.darkWake:\(rule.id.uuidString)"],
      "baseline|30000"
    )
  }

  func testRetryScheduleAndRestartResumePendingWork() async throws {
    let url = temporaryURL()
    let store = try NotificationRuntimeStore(fileURL: url, leaseID: { "lease-1" })
    try await store.commit(commit(eventID: "event-1", channels: [.telegram]))
    _ = try await store.claimPending(now: date(0))
    try await store.acknowledge(
      NotificationDeliveryOutcome(
        leaseID: "lease-1", eventID: "event-1", channelKind: .telegram,
        status: .retryScheduled(at: date(30), attempt: 2)))

    let reloaded = try NotificationRuntimeStore(fileURL: url, leaseID: { "lease-2" })
    let beforeRetry = try await reloaded.claimPending(now: date(29))
    XCTAssertTrue(beforeRetry.isEmpty)
    let resumed = try await reloaded.claimPending(now: date(30))
    XCTAssertEqual(resumed.first?.attempt, 2)
    XCTAssertEqual(resumed.first?.leaseID, "lease-2")
  }

  func testFailedAtomicWriteLeavesPreviousSnapshotReadable() async throws {
    let url = temporaryURL()
    let initial = try NotificationRuntimeStore(fileURL: url)
    try await initial.commit(commit(eventID: "event-1", channels: [.bark]))

    let failing = try NotificationRuntimeStore(
      fileURL: url,
      writer: { _, _ in throw CocoaError(.fileWriteUnknown) }
    )
    do {
      try await failing.commit(commit(eventID: "event-2", channels: [.telegram]))
      XCTFail("Expected write failure")
    } catch {}

    let reloaded = try NotificationRuntimeStore(fileURL: url)
    let snapshot = await reloaded.snapshot()
    XCTAssertEqual(snapshot.events.map(\.message.eventID), ["event-1"])
  }

  func testDuplicateEventCommitIsIdempotent() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    let transaction = commit(eventID: "event-1", channels: [.bark])
    try await store.commit(transaction)
    try await store.commit(transaction)
    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.count, 1)
  }

  func testEventRetentionDropsOldestAndKeepsTimeOrder() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL(), maximumRetainedEvents: 3)
    for index in 1...5 {
      try await store.commit(
        commit(eventID: "event-\(index)", channels: [.bark], occurredAt: date(TimeInterval(index)))
      )
    }

    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.map(\.message.eventID), ["event-3", "event-4", "event-5"])
    XCTAssertEqual(snapshot.events.map(\.createdAt), [date(3), date(4), date(5)])
  }

  func testOutOfOrderEventStillSortsBeforeRetentionTrims() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL(), maximumRetainedEvents: 3)
    for (eventID, seconds) in [("late", 40.0), ("early", 10.0), ("middle", 20.0), ("last", 50.0)] {
      try await store.commit(
        commit(eventID: eventID, channels: [.bark], occurredAt: date(seconds))
      )
    }

    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.map(\.message.eventID), ["middle", "late", "last"])
    XCTAssertEqual(snapshot.events.map(\.createdAt), [date(20), date(40), date(50)])
  }

  func testOversizedExistingFileLoadsIntactAndConvergesOnNextCommit() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var stored = NotificationRuntimeSnapshot()
    stored.events = (1...5).map { event(eventID: "old-\($0)", occurredAt: date(TimeInterval($0))) }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(stored).write(to: url)

    let store = try NotificationRuntimeStore(fileURL: url, maximumRetainedEvents: 2)
    var snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.count, 5)

    try await store.commit(commit(eventID: "new", channels: [.bark], occurredAt: date(6)))
    snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.map(\.message.eventID), ["old-5", "new"])
  }

  private func rule() -> AlertRule {
    AlertRule(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "CPU high", metricID: "cpu.total.busy",
      condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark])
  }

  private func message(eventID: String, occurredAt: Date) -> NotificationMessage {
    NotificationMessage(
      eventID: eventID,
      deviceName: "Mac",
      ruleID: rule().id.uuidString,
      state: .alert,
      occurredAt: occurredAt,
      title: "Alert",
      body: "Body",
      metric: nil
    )
  }

  private func event(eventID: String, occurredAt: Date) -> NotificationRuntimeEvent {
    NotificationRuntimeEvent(
      message: message(eventID: eventID, occurredAt: occurredAt),
      createdAt: occurredAt,
      deliveries: [.bark: NotificationRuntimeDelivery()]
    )
  }

  private func commit(
    eventID: String,
    channels: Set<NotificationChannelKind>,
    occurredAt: Date? = nil
  ) -> AlertRuntimeCommit {
    let message = message(eventID: eventID, occurredAt: occurredAt ?? date(1))
    return AlertRuntimeCommit(
      ruleID: rule().id, runtime: AlertRuleRuntime(), message: message, channels: channels)
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("MenuCue-").appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("notification-runtime-v1.json")
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }
}

final class AlertMetricProviderTests: XCTestCase {
  func testDiskCounterResetIsUnavailableAndReprimesBaseline() async {
    let sequence = LockedValueSequence([
      DiskIOCounters(readOperations: 100, writeOperations: 200),
      DiskIOCounters(readOperations: 10, writeOperations: 20),
      DiskIOCounters(readOperations: 20, writeOperations: 40),
    ])
    var dependencies = AlertMetricProviderDependencies()
    dependencies.diskIO = { sequence.next() }
    dependencies.volumes = { [] }
    let provider = SystemAlertMetricProvider(kind: .storageDetail, dependencies: dependencies)
    let requests: Set<AlertMetricRequest> = [
      AlertMetricRequest(metricID: "disk.read.operations"),
      AlertMetricRequest(metricID: "disk.write.operations"),
    ]

    let first = await provider.sample(requests: requests, at: Date(timeIntervalSince1970: 0))
    let reset = await provider.sample(requests: requests, at: Date(timeIntervalSince1970: 10))
    let resumed = await provider.sample(requests: requests, at: Date(timeIntervalSince1970: 20))

    XCTAssertTrue(first.allSatisfy { !$0.isAvailable })
    XCTAssertTrue(reset.allSatisfy { !$0.isAvailable })
    let resumedValues = resumed.compactMap(\.value)
    XCTAssertEqual(resumedValues.count, 2)
    XCTAssertTrue(resumedValues.contains(.number(1)))
    XCTAssertTrue(resumedValues.contains(.number(2)))
  }

  func testProviderCadenceUsesFastestRequestedMetric() {
    let rules = [
      AlertRule(
        name: "CPU", metricID: "cpu.total.busy",
        condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark]),
      AlertRule(
        name: "Memory", metricID: "memory.used.percent",
        condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark]),
    ]

    XCTAssertEqual(AlertMonitoringService.cadence(for: rules, provider: .system), 10)
  }
}

final class AlertMonitoringServiceTests: XCTestCase {
  func testProviderUnionSamplesOnceForMultipleRulesAndQueuesTransition() async throws {
    let url = temporaryURL()
    let store = try NotificationRuntimeStore(fileURL: url)
    let provider = RecordingAlertMetricProvider(
      kind: .system,
      values: [
        "cpu.total.busy": .number(0.95),
        "memory.used.percent": .number(0.91),
      ]
    )
    let delivery = DeliveryKickRecorder()
    let monitor = AlertMonitoringService(
      store: store,
      providers: [.system: provider],
      deviceName: { "Studio Mac" },
      delivery: { await delivery.kick() },
      sleep: { _ in try await Task.never() }
    )
    let rules = [
      rule(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", metric: "cpu.total.busy"),
      rule(id: "11111111-2222-3333-4444-555555555555", metric: "memory.used.percent"),
    ]

    try await monitor.updateRules(rules)
    await monitor.refreshOnce(provider: .system, at: date(10))

    let requests = await provider.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].count, 2)
    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.count, 2)
    let deliveryCount = await delivery.count
    XCTAssertEqual(deliveryCount, 1)
    await monitor.stop()
  }

  func testNoEnabledRulesMeansNoActiveProviderWork() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    let provider = RecordingAlertMetricProvider(
      kind: .system, values: ["cpu.total.busy": .number(1)])
    let monitor = AlertMonitoringService(
      store: store,
      providers: [.system: provider],
      sleep: { _ in try await Task.never() }
    )
    var disabled = rule(
      id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", metric: "cpu.total.busy")
    disabled.isEnabled = false

    try await monitor.updateRules([disabled])

    let activeProviders = await monitor.activeProviderKinds
    let recordedRequests = await provider.recordedRequests()
    XCTAssertTrue(activeProviders.isEmpty)
    XCTAssertTrue(recordedRequests.isEmpty)
    await monitor.stop()
  }

  func testRenderedMessageIsSnapshottedBeforeDeliveryKick() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    let provider = RecordingAlertMetricProvider(
      kind: .system, values: ["cpu.total.busy": .number(0.95)])
    let order = MonitorOrderRecorder(store: store)
    let monitor = AlertMonitoringService(
      store: store,
      providers: [.system: provider],
      deviceName: { "Work Mac" },
      delivery: { await order.deliveryKicked() },
      sleep: { _ in try await Task.never() }
    )
    var configured = rule(
      id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", metric: "cpu.total.busy")
    configured.alertTitleTemplate = "{{device.name}} / {{rule.name}}"
    configured.alertBodyTemplate = "CPU is {{metric.value}}"

    try await monitor.updateRules([configured])
    await monitor.setDeviceName("Override Mac")
    await monitor.refreshOnce(provider: .system, at: date(10))

    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.first?.message.title, "Override Mac / High")
    XCTAssertEqual(snapshot.events.first?.message.body, "CPU is 95%")
    let committedBeforeKick = await order.sawCommittedEventBeforeKick
    XCTAssertTrue(committedBeforeKick)
    await monitor.stop()
  }

  func testDarkWakeBaselineSkipsHistoryThenQueuesEachNewEventOnce() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    let delivery = DeliveryKickRecorder()
    let monitor = AlertMonitoringService(
      store: store,
      providers: [:],
      delivery: { await delivery.kick() },
      now: { Date(timeIntervalSince1970: 100) }
    )
    var darkRule = AlertRule(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Dark wake",
      metricID: "event.darkWake",
      condition: .event,
      channels: [.bark]
    )
    darkRule.alertBodyTemplate = "{{event.reason}}"
    try await monitor.updateRules([darkRule])
    let retained = WakeEvent(
      timestamp: date(90), kind: .darkWake, reason: "old", occurrence: 0)
    let fresh = WakeEvent(
      timestamp: date(101), kind: .darkWake, reason: "RTC", occurrence: 0)

    await monitor.processDarkWakeEvents([retained, fresh])
    await monitor.processDarkWakeEvents([retained, fresh])

    let snapshot = await store.snapshot()
    XCTAssertEqual(snapshot.events.map(\.message.eventID).count, 1)
    XCTAssertEqual(snapshot.events[0].message.body, "RTC")
    let deliveryCount = await delivery.count
    XCTAssertEqual(deliveryCount, 1)
  }

  func testWakeResetsCounterBaselinesAndResumesDelivery() async throws {
    let store = try NotificationRuntimeStore(fileURL: temporaryURL())
    let provider = RecordingAlertMetricProvider(kind: .system, values: [:])
    let delivery = DeliveryKickRecorder()
    let monitor = AlertMonitoringService(
      store: store,
      providers: [.system: provider],
      delivery: { await delivery.kick() },
      sleep: { _ in try await Task.never() }
    )

    await monitor.handleSystemWake()

    let resetCount = await provider.resetCount
    let deliveryCount = await delivery.count
    XCTAssertEqual(resetCount, 1)
    XCTAssertEqual(deliveryCount, 1)
  }

  private func rule(id: String, metric: AlertMetricID) -> AlertRule {
    AlertRule(
      id: UUID(uuidString: id)!, name: "High", metricID: metric,
      condition: .numeric(operator: .above, threshold: 0.9), channels: [.bark])
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("MenuCue-").appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("notification-runtime-v1.json")
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }
}

final class WakeHistoryMonitoringLifecycleTests: XCTestCase {
  func testObserversExistOnlyWhileAFeatureReferencesWakeHistory() {
    let service = makeService()
    XCTAssertEqual(service.wakeMonitoringReferenceCount, 0)
    XCTAssertFalse(service.isWakeObserverRegistered)

    service.setDarkWakeMonitoring(historyHandler: { _ in })
    XCTAssertEqual(service.wakeMonitoringReferenceCount, 1)
    XCTAssertTrue(service.isWakeObserverRegistered)

    service.setDarkWakeMonitoring(historyHandler: nil)
    XCTAssertEqual(service.wakeMonitoringReferenceCount, 0)
    XCTAssertFalse(service.isWakeObserverRegistered)

    service.startBackgroundMonitoring()
    XCTAssertTrue(service.isWakeObserverRegistered)
    service.stopBackgroundMonitoring()
    XCTAssertFalse(service.isWakeObserverRegistered)

    service.retain()
    XCTAssertTrue(service.isWakeObserverRegistered)
    service.release()
    XCTAssertFalse(service.isWakeObserverRegistered)
  }

  private func makeService() -> PowerDiagnosticsService {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("wake-history.json")
    return PowerDiagnosticsService(
      probe: EmptyPowerDiagnosticsProbe(),
      historyStore: WakeHistoryStore(fileURL: url),
      notificationCenter: NotificationCenter(),
      wakeRefreshDelay: 0
    )
  }
}

private struct EmptyPowerDiagnosticsProbe: PowerDiagnosticsProbing {
  func batteryStatus() throws -> BatteryStatus? { nil }
  func wakeStatistics() throws -> WakeStatistics {
    WakeStatistics(sleepCount: 0, darkWakeCount: 0, userWakeCount: 0)
  }
  func wakeEvents() throws -> [WakeEvent] { [] }
  func powerProfiles() throws -> PowerProfiles { PowerProfiles() }
}

private actor RecordingAlertMetricProvider: AlertMetricProviding {
  nonisolated let kind: AlertMetricProviderKind
  private let values: [String: AlertMetricValue]
  private var requests: [Set<AlertMetricRequest>] = []
  private(set) var resetCount = 0

  init(kind: AlertMetricProviderKind, values: [String: AlertMetricValue]) {
    self.kind = kind
    self.values = values
  }

  func sample(
    requests: Set<AlertMetricRequest>,
    at date: Date
  ) async -> [AlertMetricObservation] {
    self.requests.append(requests)
    return requests.map { request in
      guard let value = values[request.metricID.rawValue] else {
        return .unavailable(
          metricID: request.metricID, targetID: request.targetID, sampledAt: date)
      }
      return .value(
        metricID: request.metricID, targetID: request.targetID, value: value,
        sampledAt: date)
    }
  }

  func resetBaselines() async { resetCount += 1 }
  func recordedRequests() -> [Set<AlertMetricRequest>] { requests }
}

private actor DeliveryKickRecorder {
  private(set) var count = 0
  func kick() { count += 1 }
}

private actor MonitorOrderRecorder {
  private let store: NotificationRuntimeStore
  private(set) var sawCommittedEventBeforeKick = false

  init(store: NotificationRuntimeStore) { self.store = store }

  func deliveryKicked() async {
    sawCommittedEventBeforeKick = await !store.snapshot().events.isEmpty
  }
}

extension Task where Success == Never, Failure == Never {
  fileprivate static func never() async throws -> Never {
    try await Task.sleep(nanoseconds: .max)
    fatalError("Unreachable")
  }
}

private final class LockedValueSequence<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Value]

  init(_ values: [Value]) { self.values = values }

  func next() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return values.count > 1 ? values.removeFirst() : values[0]
  }
}

private final class LockedStringSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) { self.values = values }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.count > 1 ? values.removeFirst() : values[0]
  }
}

extension AlertRulePhase {
  fileprivate var isPendingAlert: Bool {
    if case .pendingAlert = self { return true }
    return false
  }

  fileprivate var isActive: Bool {
    if case .active = self { return true }
    return false
  }

  fileprivate var isPendingRecovery: Bool {
    if case .pendingRecovery = self { return true }
    return false
  }
}
