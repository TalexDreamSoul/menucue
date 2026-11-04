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
    scheduler.update(settings: settings, deviceName: "Studio Mac", timeZone: shanghai)
    scheduler.update(settings: settings, deviceName: "Studio Mac", timeZone: shanghai)
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

      scheduler.update(settings: disabled, deviceName: "Studio Mac", timeZone: shanghai)
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

  func testAnchorZoneChangeAcrossDateLineDoesNotReplayDailyOccurrence() async throws {
    let firstInstant = localDate(day: 5, hour: 11, minute: 0)
    let fixture = try makeFixture(at: firstInstant)
    var rule = reminder(schedule: .daily(hour: 17, minute: 30))
    rule.lidCloseAfterHour = 11
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    // The lid path reserves the Shanghai civil day before the asynchronous enqueue settles.
    scheduler.update(settings: settings, deviceName: "Studio Mac", timeZone: shanghai)
    scheduler.handleLidStateChange()
    fixture.date = localDate(day: 5, hour: 11, minute: 30)
    scheduler.update(settings: settings, deviceName: "Studio Mac", timeZone: honolulu)
    scheduler.handleLidStateChange()
    await scheduler.settle()

    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message.eventID), [
      "reminder|\(rule.id.uuidString)|2026-01-05"
    ])

    let emptyStore = try NotificationRuntimeStore(
      fileURL: fixture.fileURL.deletingLastPathComponent().appendingPathComponent("date-line-empty.json"))
    let restarted = await fixture.makeScheduler(store: emptyStore)
    fixture.date = localDate(day: 5, hour: 17, minute: 30, timeZone: honolulu)
    await tick(restarted, settings: settings, timeZone: honolulu)
    let replayed = await emptyStore.snapshot().events
    XCTAssertEqual(replayed, [], "a civil day already consumed in Shanghai stays consumed after relaunch")
    fixture.date = localDate(day: 6, hour: 17, minute: 30, timeZone: honolulu)
    await tick(restarted, settings: settings, timeZone: honolulu)
    let nextDay = await emptyStore.snapshot().events
    XCTAssertEqual(nextDay.map(\.message.eventID), ["reminder|\(rule.id.uuidString)|2026-01-06"])
  }

  func testDailyMissingSpringTimeUsesFoundationNextOccurrence() async throws {
    let fixture = try makeFixture(
      at: localDate(day: 8, hour: 1, minute: 59, second: 59, month: 3, timeZone: losAngeles))
    let rule = reminder(schedule: .daily(hour: 2, minute: 30))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let before = await fixture.store.snapshot().events
    XCTAssertTrue(before.isEmpty)

    fixture.date = localDate(day: 8, hour: 3, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message.eventID), [
      "reminder|\(rule.id.uuidString)|2026-03-08"
    ])
  }

  func testDailyRepeatedAutumnTimeFiresOnlyOnce() async throws {
    let firstOccurrence = localDate(day: 1, hour: 1, minute: 30, month: 11, timeZone: losAngeles)
    let fixture = try makeFixture(at: firstOccurrence)
    let rule = reminder(schedule: .daily(hour: 1, minute: 30))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let firstEvents = await fixture.store.snapshot().events
    XCTAssertEqual(firstEvents.map(\.message), [
      message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-11-01", at: firstOccurrence)
    ])
    fixture.date = firstOccurrence.addingTimeInterval(60 * 60)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events, firstEvents, "the repeated civil hour shares one daily occurrence")
  }

  func testHourlyWindowNeverCrossesAnchorDayEndAtHour23() async throws {
    let fixture = try makeFixture(
      at: localDate(day: 8, hour: 21, minute: 59, month: 3, timeZone: losAngeles))
    let rule = reminder(schedule: .everyHours(hours: 1, startHour: 22, endHour: 23))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    fixture.date = localDate(day: 8, hour: 22, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    fixture.date = localDate(day: 8, hour: 23, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    fixture.date = localDate(day: 9, hour: 0, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)

    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message.eventID), [
      occurrenceID(rule: rule, at: localDate(day: 8, hour: 22, month: 3, timeZone: losAngeles)),
      occurrenceID(rule: rule, at: localDate(day: 8, hour: 23, month: 3, timeZone: losAngeles))
    ], "the next day cannot inherit a prior day's 00:00 slot")
  }

  func testHourlyWindowSkipsSpringGapWithoutLooping() async throws {
    let fixture = try makeFixture(
      at: localDate(day: 8, hour: 0, month: 3, timeZone: losAngeles))
    let rule = reminder(schedule: .everyHours(hours: 2, startHour: 0, endHour: 23))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings, timeZone: losAngeles)
    fixture.date = localDate(day: 8, hour: 3, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message.eventID), [
      occurrenceID(rule: rule, at: localDate(day: 8, hour: 0, month: 3, timeZone: losAngeles)),
      occurrenceID(rule: rule, at: fixture.date)
    ], "the missing 02:00 hour must not duplicate or stall slots")
  }

  func testEveryDaysUsesCivilCalendarDaysAcrossSpringDST() async throws {
    let fixture = try makeFixture(
      at: localDate(day: 7, hour: 10, minute: 15, month: 3, timeZone: losAngeles))
    let rule = reminder(schedule: .everyDays(days: 7))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings, timeZone: losAngeles)
    fixture.date = localDate(day: 14, hour: 10, minute: 14, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let before = await fixture.store.snapshot().events
    XCTAssertEqual(before.count, 0)

    fixture.date = localDate(day: 14, hour: 10, minute: 15, month: 3, timeZone: losAngeles)
    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message), [
      message(rule: rule, eventID: occurrenceID(rule: rule, at: fixture.date), at: fixture.date)
    ], "seven calendar days remain seven across the 23-hour day")
  }

  func testLiveAnchorChangeMakesShanghaiDailyTimeImmediatelyDue() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 11))
    let rule = reminder(schedule: .daily(hour: 11, minute: 0))
    let settings = settings(for: rule)
    let scheduler = await fixture.makeScheduler()

    await tick(scheduler, settings: settings, timeZone: losAngeles)
    let before = await fixture.store.snapshot().events
    XCTAssertEqual(before, [])
    await tick(scheduler, settings: settings, timeZone: shanghai)
    let after = await fixture.store.snapshot().events
    XCTAssertEqual(after.map(\.message), [
      message(rule: rule, eventID: "reminder|\(rule.id.uuidString)|2026-01-05", at: fixture.date)
    ])
  }

  func testLegacyRuntimeWithoutCivilDayStateStillSuppressesSameDayAfterRestart() async throws {
    let instant = localDate(day: 5, hour: 11)
    let fixture = try makeFixture(at: instant)
    let rule = reminder(schedule: .daily(hour: 11, minute: 0))
    let legacy: [String: [String: Date]] = [
      "lastFired": [rule.id.uuidString: instant], "anchors": [:]
    ]
    fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "reminderRuntime.v1")
    let scheduler = await fixture.makeScheduler()
    await tick(scheduler, settings: settings(for: rule))
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events, [])
  }

  func testHourlyAutumnRepeatUsesDistinctAbsoluteOccurrences() async throws {
    let first = localDate(day: 1, hour: 1, month: 11, timeZone: losAngeles)
    let fixture = try makeFixture(at: first)
    let rule = reminder(schedule: .everyHours(hours: 1, startHour: 1, endHour: 2))
    let scheduler = await fixture.makeScheduler()
    await tick(scheduler, settings: settings(for: rule), timeZone: losAngeles)
    fixture.date = first.addingTimeInterval(3_600)
    await tick(scheduler, settings: settings(for: rule), timeZone: losAngeles)
    let events = await fixture.store.snapshot().events
    XCTAssertEqual(events.map(\.message.eventID), [
      occurrenceID(rule: rule, at: first),
      occurrenceID(rule: rule, at: first.addingTimeInterval(3_600))
    ])
  }

  func testHourlyWindowDoesNotTreatAnOvernightGapAsAContinuingPreviousDay() async throws {
    let fixture = try makeFixture(at: localDate(day: 5, hour: 23))
    let rule = reminder(schedule: .everyHours(hours: 2, startHour: 9, endHour: 18))
    let scheduler = await fixture.makeScheduler()
    let settings = settings(for: rule)
    await tick(scheduler, settings: settings)
    fixture.date = localDate(day: 6, hour: 8, minute: 59)
    await tick(scheduler, settings: settings)
    let overnight = await fixture.store.snapshot().events
    XCTAssertEqual(overnight, [])
    fixture.date = localDate(day: 6, hour: 9)
    await tick(scheduler, settings: settings)
    let morning = await fixture.store.snapshot().events
    XCTAssertEqual(morning.map(\.message.eventID), [occurrenceID(rule: rule, at: fixture.date)])
  }

  private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
  private let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
  private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

  private func tick(
    _ scheduler: ReminderScheduler,
    settings: NotificationSettings,
    timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!
  ) async {
    scheduler.update(settings: settings, deviceName: "Studio Mac", timeZone: timeZone)
    await scheduler.settle()
  }
  private func localDate(
    day: Int,
    hour: Int,
    minute: Int = 0,
    second: Int = 0,
    month: Int = 1,
    timeZone: TimeZone? = nil
  ) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone ?? shanghai
    return calendar.date(
      from: DateComponents(
        year: 2026, month: month, day: day, hour: hour, minute: minute, second: second
      ))!
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
