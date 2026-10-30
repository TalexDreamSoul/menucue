import Foundation
import XCTest

@testable import MenuCue

@MainActor
final class ReminderSchedulerTests: XCTestCase {
  func testDailyReminderWaitsUntilElevenAndFiresOnlyOncePerDay() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 10, minute: 59, second: 59))
    let rule = reminder(schedule: .daily(hour: 11, minute: 0))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings)
    var events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [], "The reminder must not fire before 11:00")

    fixture.date = localDate(day: 5, hour: 11)
    await tick(scheduler, settings: settings)
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events.count, 1)
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(
      event.message,
      message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-05", at: fixture.date))
    XCTAssertEqual(Set(event.deliveries.keys), [.bark])
    XCTAssertEqual(event.deliveries[.bark]?.state, .pending)

    // Repeated ticks include a burst before the previous enqueue has finished.
    scheduler.update(settings: settings, deviceName: "Studio Mac")
    scheduler.update(settings: settings, deviceName: "Studio Mac")
    await scheduler.settle()
    fixture.date = localDate(day: 5, hour: 12, minute: 59)
    await tick(scheduler, settings: settings)
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [event])

    fixture.date = localDate(day: 6, hour: 10, minute: 59, second: 59)
    await tick(scheduler, settings: settings)
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [event])

    fixture.date = localDate(day: 6, hour: 11, second: 30)
    await tick(scheduler, settings: settings)
    events = await fixture.store.snapshot().events
    XCTAssertEqual(
      events.map(\.message),
      [
        event.message,
        message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-06", at: fixture.date),
      ])
  }

  func testEverySevenDaysUsesItsFirstTickAsBaselineAndWaitsForEachFullPeriod() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 10, minute: 15))
    let rule = reminder(schedule: .everyDays(days: 7))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings)
    var events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [], "Establishing a baseline must not immediately remind the user")

    var expected: [NotificationMessage] = []
    for day in [12, 19] {
      fixture.date = localDate(day: day, hour: 10, minute: 14, second: 59)
      await tick(scheduler, settings: settings)
      events = await fixture.store.snapshot().events
      XCTAssertEqual(events.map(\.message), expected, "The seven-day interval has not elapsed")

      fixture.date = localDate(day: day, hour: 10, minute: 15)
      await tick(scheduler, settings: settings)
      expected.append(message(rule: rule, eventID: occurrenceID(rule: rule, at: fixture.date), at: fixture.date))
      events = await fixture.store.snapshot().events
      XCTAssertEqual(events.map(\.message), expected)
      XCTAssertEqual(events.map { Set($0.deliveries.keys) }, Array(repeating: [.bark], count: expected.count))

      await tick(scheduler, settings: settings)
      events = await fixture.store.snapshot().events
      XCTAssertEqual(events.map(\.message), expected, "A due period is not a new event on every tick")
    }
  }

  func testEveryTwoHoursUsesOnlySlotsBetweenTheStartAndEndHours() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 8, minute: 59, second: 59))
    let rule = reminder(schedule: .everyHours(hours: 2, startHour: 9, endHour: 18))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()
    let steps: [(hour: Int, minute: Int, newSlot: Int?)] = [
      (8, 59, nil),
      (9, 0, 9),
      (9, 30, nil),
      (10, 59, nil),
      (11, 0, 11),
      (13, 0, 13),
      (15, 0, 15),
      (17, 0, 17),
      (18, 0, nil),
      (19, 0, nil),
      (20, 0, nil),
    ]
    var expected: [NotificationMessage] = []

    for step in steps {
      fixture.date = localDate(day: 5, hour: step.hour, minute: step.minute)
      await tick(scheduler, settings: settings)
      if let slot = step.newSlot {
        let occurrence = localDate(day: 5, hour: slot)
        expected.append(message(rule: rule, eventID: occurrenceID(rule: rule, at: occurrence), at: fixture.date))
      }
      let events = await fixture.store.snapshot().events
      XCTAssertEqual(events.map(\.message), expected, "Unexpected water reminder at \(step.hour):\(step.minute)")
      XCTAssertEqual(events.map { Set($0.deliveries.keys) }, Array(repeating: [.bark], count: expected.count))
    }

    fixture.date = localDate(day: 6, hour: 9)
    await tick(scheduler, settings: settings)
    expected.append(message(rule: rule, eventID: occurrenceID(rule: rule, at: fixture.date), at: fixture.date))
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), expected, "The next local day's first slot must become eligible again")
  }

  func testLidCloseRequiresAClosedLidAndTheAfterHourThenDeduplicatesTheLocalDay() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 16, minute: 59, second: 59))
    var rule = reminder(schedule: .daily(hour: 23, minute: 0))
    rule.lidCloseAfterHour = 17
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()
    await tick(scheduler, settings: settings)

    scheduler.handleLidStateChange()
    await scheduler.settle()
    var events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [], "A closed lid before 17:00 is not a clock-out reminder")

    fixture.date = localDate(day: 5, hour: 17)
    fixture.isLidClosed = false
    scheduler.handleLidStateChange()
    await scheduler.settle()
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [], "A lid-open notification must not trigger the reminder")

    fixture.isLidClosed = true
    scheduler.handleLidStateChange()
    await scheduler.settle()
    let first = message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-05", at: fixture.date)
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), [first])
    XCTAssertEqual(events.map { Set($0.deliveries.keys) }, [[.bark]])

    fixture.date = localDate(day: 5, hour: 18)
    scheduler.handleLidStateChange()
    scheduler.handleLidStateChange()
    await scheduler.settle()
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), [first])

    fixture.date = localDate(day: 6, hour: 16, minute: 59, second: 59)
    scheduler.handleLidStateChange()
    await scheduler.settle()
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), [first])

    fixture.date = localDate(day: 6, hour: 17)
    scheduler.handleLidStateChange()
    await scheduler.settle()
    events = await fixture.store.snapshot().events
    XCTAssertEqual(
      events.map(\.message),
      [first, message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-06", at: fixture.date)])
  }

  func testScheduledAndLidCloseTriggersShareTheSameDailyOccurrence() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 17))
    var rule = reminder(schedule: .daily(hour: 17, minute: 30))
    rule.lidCloseAfterHour = 17
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()
    await tick(scheduler, settings: settings)

    scheduler.handleLidStateChange()
    await scheduler.settle()
    let first = message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-05", at: fixture.date)
    fixture.date = localDate(day: 5, hour: 17, minute: 30)
    await tick(scheduler, settings: settings)
    var events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), [first], "The scheduled time must not repeat a lid-close reminder")

    fixture.date = localDate(day: 6, hour: 17, minute: 30)
    await tick(scheduler, settings: settings)
    let second = message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-06", at: fixture.date)
    fixture.date = localDate(day: 6, hour: 18)
    scheduler.handleLidStateChange()
    await scheduler.settle()
    events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), [first, second], "Closing the lid must not repeat the scheduled reminder")
  }

  func testRestartRetainsOccurrenceIdentityAndDoesNotRequeueEvenWithoutOutboxHistory() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 11))
    let rule = reminder(schedule: .daily(hour: 11, minute: 0))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()
    await tick(scheduler, settings: settings)
    let original = await fixture.store.snapshot().events
    XCTAssertEqual(original.map(\.message.eventID), ["reminder|\(rule.id.uuidString)|2026-01-05"])

    fixture.date = localDate(day: 5, hour: 11, minute: 30)
    let reopenedStore = try NotificationRuntimeStore(fileURL: fixture.fileURL)
    let restarted = await fixture.makeScheduler(store: reopenedStore)
    await tick(restarted, settings: settings)
    let reopenedEvents = await reopenedStore.snapshot().events
    XCTAssertEqual(reopenedEvents, original)

    // An empty outbox prevents store-level eventID deduplication from hiding lost scheduler state.
    let emptyStore = try NotificationRuntimeStore(
      fileURL: fixture.fileURL.deletingLastPathComponent().appendingPathComponent("empty-outbox.json"))
    let restartedWithoutHistory = await fixture.makeScheduler(store: emptyStore)
    await tick(restartedWithoutHistory, settings: settings)
    var events = await emptyStore.snapshot().events
    XCTAssertEqual(events, [], "Saved occurrence state must survive independently of retained outbox history")

    fixture.date = localDate(day: 6, hour: 11)
    await tick(restartedWithoutHistory, settings: settings)
    events = await emptyStore.snapshot().events
    XCTAssertEqual(
      events.map(\.message),
      [message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-06", at: fixture.date)])
  }

  func testDisabledMasterRuleOrAllChannelsSuppressScheduledAndLidCloseEvents() async throws {
    let cases: [(name: String, disable: (inout NotificationSettings) -> Void)] = [
      ("global switch", { $0.isGloballyEnabled = false }),
      ("rule switch", { $0.reminders[0].isEnabled = false }),
      ("all rule channels", { settings in
        settings.updateChannel(.bark) { $0.isEnabled = false }
        settings.updateChannel(.telegram) { $0.isEnabled = false }
      }),
    ]

    for testCase in cases {
      let fixture = try makeFixture(at: localDate(day: 5, hour: 17))
      var rule = reminder(schedule: .daily(hour: 17, minute: 0))
      rule.lidCloseAfterHour = 17
      let enabled = settings(for: rule)
      var disabled = enabled
      testCase.disable(&disabled)
      let scheduler = await fixture.makeScheduler()

      scheduler.update(settings: disabled, deviceName: "Studio Mac")
      scheduler.handleLidStateChange()
      await scheduler.settle()
      var events = await fixture.store.snapshot().events
      XCTAssertEqual(events, [], "Disabled \(testCase.name) must suppress both trigger paths")

      await tick(scheduler, settings: enabled)
      events = await fixture.store.snapshot().events
      XCTAssertEqual(
        events.map(\.message),
        [message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-05", at: fixture.date)],
        "Reenabling \(testCase.name) must not find the suppressed occurrence already consumed")
      XCTAssertEqual(events.map { Set($0.deliveries.keys) }, [[.bark]])
    }
  }

  private func tick(_ scheduler: ReminderScheduler, settings: NotificationSettings) async {
    scheduler.update(settings: settings, deviceName: "Studio Mac")
    await scheduler.settle()
  }

  private func makeFixture(at date: Date) throws -> ReminderSchedulerFixture {
    let suite = "ReminderSchedulerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MenuCue-ReminderScheduler-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suite)
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    }
    return try ReminderSchedulerFixture(defaults: defaults, directory: directory, date: date)
  }

  private func reminder(schedule: ReminderSchedule) -> ReminderRule {
    ReminderRule(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Water",
      isEnabled: true,
      schedule: schedule,
      title: "Drink water",
      body: "Take a short break and drink some water.",
      channels: [.bark, .telegram])
  }

  private func settings(for rule: ReminderRule) -> NotificationSettings {
    NotificationSettings(
      isGloballyEnabled: true,
      channels: [
        .bark: NotificationChannelSettings(isEnabled: true),
        .telegram: NotificationChannelSettings(isEnabled: false),
      ],
      rules: [],
      reminders: [rule])
  }

  private func message(rule: ReminderRule, eventID: String, at date: Date) -> NotificationMessage {
    NotificationMessage(
      eventID: eventID,
      deviceName: "Studio Mac",
      ruleID: rule.id.uuidString,
      state: .alert,
      occurredAt: date,
      title: rule.title,
      body: rule.body,
      metric: nil)
  }

  private func occurrenceID(rule: ReminderRule, at date: Date) -> String {
    "reminder|\(rule.id.uuidString)|\(Int(date.timeIntervalSince1970))"
  }

  private func localDate(day: Int, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar.date(
      from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute, second: second))!
  }
}

@MainActor
private final class ReminderSchedulerFixture {
  let defaults: UserDefaults
  let fileURL: URL
  let store: NotificationRuntimeStore
  var date: Date
  var isLidClosed = true

  init(defaults: UserDefaults, directory: URL, date: Date) throws {
    self.defaults = defaults
    self.date = date
    self.fileURL = directory.appendingPathComponent("notification-runtime-v1.json")
    self.store = try NotificationRuntimeStore(fileURL: fileURL)
  }

  func makeScheduler(store: NotificationRuntimeStore? = nil) async -> ReminderScheduler {
    let store = store ?? self.store
    let dispatcher = NotificationDeliveryDispatcher(
      store: store,
      configuration: NotificationConfigurationService(
        secrets: InMemoryNotificationSecretStore(), transport: UnusedReminderTransport()))
    // Keep the real dispatcher paused: assertions concern the durable outbox, not delivery.
    await dispatcher.update(settings: NotificationSettings(isGloballyEnabled: false, reminders: []))
    return ReminderScheduler(
      store: store,
      dispatcher: dispatcher,
      defaults: defaults,
      now: { self.date },
      isClamshellClosed: { self.isLidClosed })
  }
}

private struct UnusedReminderTransport: NotificationHTTPTransport {
  func data(for request: URLRequest) async throws -> NotificationHTTPResponse {
    XCTFail("Scheduler tests must not send notifications")
    throw NotificationDeliveryError.networkUnavailable
  }
}
