import AppKit
import Foundation
import XCTest

@testable import MenuCue

/// The system side of the appearance feature is **edge triggered**: macOS's own Light/Dark
/// setting is written when the schedule's target flips, and left alone in between — where it
/// belongs to whoever else set it (macOS's Auto schedule, Control Center, the Dark Mode
/// quick action). These tests read that promise where macOS does: the argument handed to the
/// one function that can change the setting. That function is injected everywhere here, so
/// no test in this file reaches System Events.
///
/// `currentSystemDarkMode` is left uncovered on purpose: it reads the `AppleInterfaceStyle`
/// value out of macOS's real global preferences domain, which has no injection point. Any
/// test would have to write that domain first, changing the user's own system appearance and
/// risking leaving it behind, so the read is exercised only by the app.
@MainActor
final class SystemAppearanceScheduleTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var initialAppAppearance: NSAppearance?

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
    // The process-wide appearance is shared with every other test in this process; put back
    // whatever the app started with.
    initialAppAppearance = NSApp.appearance
    suiteName = "MenuCueTests.SystemAppearanceScheduleTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    NSApp.appearance = initialAppAppearance
    initialAppAppearance = nil
    super.tearDown()
  }

  /// The regression this file exists for: the schedule used to re-assert its target on every
  /// tick, so a manual switch — or macOS's own sunrise switch — was undone seconds later.
  /// Only the edge may reach macOS; the ticks after it must not.
  func testTheScheduledEdgeWritesOnceAndTheTicksAfterItWriteNothing() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)
    let settings = makeSettings(mode: .automaticByTimeZone)

    service.apply(settings: settings, date: instant(hour: 18, minute: 59, second: 59))
    XCTAssertEqual(recorder.writtenValues, [false], "the light half of the day is written once")

    service.apply(settings: settings, date: instant(hour: 18, minute: 59, second: 59))
    service.apply(settings: settings, date: instant(hour: 18, minute: 59, second: 59))
    XCTAssertEqual(recorder.writtenValues, [false], "the ticks in between write nothing")

    service.apply(settings: settings, date: instant(hour: 19, minute: 0, second: 0))
    XCTAssertEqual(recorder.writtenValues, [false, true], "crossing 19:00 writes the dark target")

    service.apply(settings: settings, date: instant(hour: 19, minute: 0, second: 1))
    XCTAssertEqual(recorder.writtenValues, [false, true], "the ticks after the edge write nothing")
  }

  /// Off has to write nothing at all, and it has to forget what it wrote: turning the switch
  /// back on re-asserts the schedule even when that resolves to the value already in force
  /// when it was switched off — otherwise the system keeps an appearance nobody asked for.
  func testTurningTheSwitchOffWritesNothingAndTurningItBackOnReAssertsTheSameValue() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)

    service.apply(settings: makeSettings(mode: .automaticByTimeZone), date: instant(hour: 12))
    service.apply(settings: makeSettings(mode: .automaticByTimeZone), date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [false])

    service.apply(
      settings: makeSettings(mode: .automaticByTimeZone, appliesSystemAppearance: false),
      date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [false], "nothing is written while the switch is off")

    service.apply(settings: makeSettings(mode: .automaticByTimeZone), date: instant(hour: 12))
    XCTAssertEqual(
      recorder.writtenValues, [false, false],
      "re-enabling re-asserts the schedule, same value as before and all")
  }

  /// Following the system resolves no target at all, so there is nothing to assert — not
  /// even after a retry.
  func testFollowingTheSystemNeverWrites() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)
    let settings = makeSettings(mode: .system)

    service.apply(settings: settings, date: instant(hour: 12))
    service.retrySystemAppearance(settings: settings, date: instant(hour: 20))

    XCTAssertTrue(
      recorder.writtenValues.isEmpty, "follow-the-system means this service writes nothing")
  }

  /// The two fixed modes resolve concrete values, and each edge between them is one write.
  func testTheFixedModesWriteTheirResolvedValueOnce() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)

    service.apply(settings: makeSettings(mode: .light), date: instant(hour: 12))
    service.apply(settings: makeSettings(mode: .light), date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [false])

    service.apply(settings: makeSettings(mode: .dark), date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [false, true])

    service.apply(settings: makeSettings(mode: .dark), date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [false, true])
  }

  /// The hour comes from the reference zone the user picked, not from this Mac's clock. One
  /// instant resolves to dark in Asia/Shanghai (04:30) and light in America/Los_Angeles
  /// (12:30), so an implementation reading the machine's zone would write the same value
  /// twice instead of flipping — whichever zone the machine happens to be in.
  func testTheScheduleFollowsTheReferenceTimeZoneRatherThanTheMachineClock() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)
    let utcInstant = instant(in: "UTC", hour: 20, minute: 30)

    service.apply(
      settings: makeSettings(mode: .automaticByTimeZone, referenceTimeZoneID: "Asia/Shanghai"),
      date: utcInstant)
    XCTAssertEqual(recorder.writtenValues, [true], "04:30 in the reference zone is night")

    service.apply(
      settings: makeSettings(mode: .automaticByTimeZone, referenceTimeZoneID: "America/Los_Angeles"),
      date: utcInstant)
    XCTAssertEqual(recorder.writtenValues, [true, false], "12:30 in the new reference zone is day")
  }

  /// 07:00 and 19:00 are the only two instants the schedule turns on, and the daylight
  /// window is half-open: the second before 07:00 is still night, 19:00 itself is night.
  func testTheDaylightWindowIsHalfOpenAtSevenAndNineteen() {
    let rows: [(label: String, hour: Int, minute: Int, second: Int, isDarkMode: Bool)] = [
      ("06:59:59 is still night", 6, 59, 59, true),
      ("07:00:00 is day", 7, 0, 0, false),
      ("18:59:59 is still day", 18, 59, 59, false),
      ("19:00:00 is night", 19, 0, 0, true),
    ]

    for row in rows {
      let recorder = SystemAppearanceWriteRecorder()
      let service = AppearanceService(writeSystemAppearance: recorder.write)
      service.apply(
        settings: makeSettings(mode: .automaticByTimeZone),
        date: instant(hour: row.hour, minute: row.minute, second: row.second))
      XCTAssertEqual(recorder.writtenValues, [row.isDarkMode], row.label)
    }
  }

  /// A write macOS refuses (the Automation grant missing) has to surface — that is what the
  /// permission banner is built on — and it must not be re-sent on the next tick, because a
  /// refusal is not something the next tick can repair. Only an explicit retry writes again,
  /// and a retry that succeeds clears the refusal.
  func testARefusedWriteIsReportedRecordedAndNotRepeatedUntilAnExplicitRetry() {
    let recorder = SystemAppearanceWriteRecorder()
    let refusal = AppleScriptRunner.Failure.executionFailed("denied")
    recorder.result = .failure(refusal)
    let service = AppearanceService(writeSystemAppearance: recorder.write)
    let settings = makeSettings(mode: .dark)

    service.apply(settings: settings, date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [true])
    XCTAssertEqual(service.systemWriteFailure, refusal)

    service.apply(settings: settings, date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [true], "a refusal is not re-sent on the next tick")

    recorder.result = .success(())
    service.retrySystemAppearance(settings: settings, date: instant(hour: 12))
    XCTAssertEqual(recorder.writtenValues, [true, true], "the retry writes the schedule again")
    XCTAssertNil(service.systemWriteFailure, "a retry that works clears the refusal")
  }

  /// The row that shows the refusal must stop claiming a failure once nothing is being
  /// applied, or switching the feature off would leave a permission banner behind.
  func testTurningTheSwitchOffClearsTheReportedRefusal() {
    let recorder = SystemAppearanceWriteRecorder()
    recorder.result = .failure(.executionFailed("denied"))
    let service = AppearanceService(writeSystemAppearance: recorder.write)

    service.apply(settings: makeSettings(mode: .dark), date: instant(hour: 12))
    XCTAssertNotNil(service.systemWriteFailure)

    service.apply(
      settings: makeSettings(mode: .dark, appliesSystemAppearance: false),
      date: instant(hour: 12))
    XCTAssertNil(service.systemWriteFailure)
    XCTAssertEqual(recorder.writtenValues, [true])
  }

  /// The Dark Mode quick action writes on the user's behalf, and it must not look to the
  /// schedule like the schedule itself has been applied: the memory holds what the schedule
  /// last wrote, not what the quick action did.
  func testAManualWriteDoesNotConsumeTheScheduleMemory() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)

    service.setSystemDarkMode(true)
    XCTAssertEqual(recorder.writtenValues, [true])

    service.apply(settings: makeSettings(mode: .dark), date: instant(hour: 12))
    XCTAssertEqual(
      recorder.writtenValues, [true, true],
      "the schedule still asserts its own target after the quick action wrote it")
  }

  /// Edge triggering means the schedule does not take a manual switch back: once the day's
  /// target has been written, the ticks up to the next edge leave the manual change alone,
  /// and the edge itself asserts the schedule again.
  func testTheNextTickLeavesAManualChangeAloneUntilTheFollowingEdge() {
    let recorder = SystemAppearanceWriteRecorder()
    let service = AppearanceService(writeSystemAppearance: recorder.write)
    let settings = makeSettings(mode: .automaticByTimeZone)

    service.apply(settings: settings, date: instant(hour: 20))
    XCTAssertEqual(recorder.writtenValues, [true], "the night edge is dark")

    service.setSystemDarkMode(false)
    XCTAssertEqual(recorder.writtenValues, [true, false], "the user goes light by hand")

    service.apply(settings: settings, date: instant(hour: 20))
    XCTAssertEqual(
      recorder.writtenValues, [true, false], "the next tick does not claw the manual change back")

    service.apply(settings: settings, date: instant(hour: 8))
    XCTAssertEqual(
      recorder.writtenValues, [true, false, false],
      "the morning edge asserts the schedule again")
  }

  // MARK: - Fixtures

  private func makeSettings(
    mode: AppearanceMode,
    referenceTimeZoneID: String = "Asia/Shanghai",
    appliesSystemAppearance: Bool = true
  ) -> AppSettings {
    var settings = SettingsStore(defaults: defaults).load()
    settings.appearanceMode = mode
    settings.appearanceTimeZoneID = referenceTimeZoneID
    settings.appliesSystemAppearance = appliesSystemAppearance
    return settings
  }

  /// A fixed wall-clock instant in a reference zone, so the 07:00/19:00 edges are driven by
  /// the date handed to `apply` rather than by when the suite happens to run.
  private func instant(
    in referenceTimeZoneID: String = "Asia/Shanghai",
    hour: Int,
    minute: Int = 0,
    second: Int = 0
  ) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: referenceTimeZoneID)!
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 15
    components.hour = hour
    components.minute = minute
    components.second = second
    return calendar.date(from: components)!
  }
}

/// Stands in for the one function that can change macOS's own Light/Dark setting, and keeps
/// what it was asked to write. Nothing in this file reaches System Events.
private final class SystemAppearanceWriteRecorder {
  private(set) var writtenValues: [Bool] = []
  /// What the next write returns; a refused write is what the refusal banner is built on.
  var result: Result<Void, AppleScriptRunner.Failure> = .success(())

  func write(_ isDarkMode: Bool) -> Result<Void, AppleScriptRunner.Failure> {
    writtenValues.append(isDarkMode)
    return result
  }
}
