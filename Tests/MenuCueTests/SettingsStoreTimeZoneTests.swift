import Foundation
import XCTest
@testable import MenuCue

final class SettingsStoreTimeZoneTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()

        suiteName = "MenuCueTests.SettingsStoreTimeZoneTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil

        super.tearDown()
    }

    func testEmptyDefaultsResolveSystemClockAsFirstClock() {
        let settings = store.load()
        let firstClock = settings.clockTimeZones.first

        XCTAssertEqual(settings.clockEntries.first?.id, ClockEntry.systemID)
        XCTAssertEqual(firstClock?.identifier, TimeZone.autoupdatingCurrent.identifier)
        XCTAssertTrue(firstClock?.isSystem ?? false)
    }
    func testLegacyClockKeysMigrateEnabledSystemBeforeCustomClocksInOriginalOrder() {
        defaults.set(true, forKey: "showsSystemTimeZone")
        defaults.set(
            [TimeZone.autoupdatingCurrent.identifier, "America/New_York", "Asia/Tokyo"],
            forKey: "selectedTimeZoneIDs"
        )

        let settings = store.load()

        XCTAssertEqual(
            settings.clockEntries.map(\.id),
            [ClockEntry.systemID, "America/New_York", "Asia/Tokyo"]
        )
    }

    func testLegacyClockKeysMigrateHiddenSystemAndDiscardInvalidOrDuplicateCustomClocks() {
        defaults.set(false, forKey: "showsSystemTimeZone")
        defaults.set(
            ["America/Los_Angeles", "Not/AZone", "America/Los_Angeles", "Asia/Shanghai"],
            forKey: "selectedTimeZoneIDs"
        )

        let settings = store.load()

        XCTAssertEqual(settings.clockEntries.map(\.id), ["America/Los_Angeles", "Asia/Shanghai"])
    }

    func testEmptyDefaultsLoadMondayAsCalendarWeekStartDay() {
        let settings = store.load()

        XCTAssertEqual(settings.calendarWeekStartDay, .monday)
    }

    func testCalendarWeekStartDayPersistsAcrossSaveAndLoad() {
        var settings = store.load()
        settings.calendarWeekStartDay = .sunday

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.calendarWeekStartDay, .sunday)
    }

    func testQuickEventDraftRoundsStartDateUpToNextHourAndSetsOneHourDuration() throws {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let requestedStart = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 1,
            day: 15,
            hour: 9,
            minute: 37,
            second: 42
        )))
        let expectedStart = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 1,
            day: 15,
            hour: 10,
            minute: 0,
            second: 0
        )))

        let draft = QuickEventDraft(startDate: requestedStart, calendarID: "primary")

        XCTAssertEqual(draft.startDate, expectedStart)
        XCTAssertEqual(draft.endDate, expectedStart.addingTimeInterval(60 * 60))
    }

    func testOverviewTimeZonePersistsSeparatelyFromClockEntriesAndAppearanceTimeZone() {
        var settings = store.load()
        settings.replaceClockEntries([
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Asia/Tokyo")!
        ])
        settings.appearanceTimeZoneID = "Europe/London"
        settings.overviewTimeZoneID = "Pacific/Honolulu"

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.overviewTimeZoneID, "Pacific/Honolulu")
        XCTAssertEqual(reloaded.overviewTimeZone.identifier, "Pacific/Honolulu")
        XCTAssertEqual(reloaded.clockEntries.map(\.id), ["America/New_York", "Asia/Tokyo"])
        XCTAssertEqual(reloaded.appearanceTimeZoneID, "Europe/London")
        XCTAssertEqual(reloaded.appearanceTimeZone.identifier, "Europe/London")
        XCTAssertNotEqual(reloaded.overviewTimeZoneID, reloaded.clockEntries.first?.id)
        XCTAssertNotEqual(reloaded.overviewTimeZoneID, reloaded.appearanceTimeZoneID)
    }

    func testStatusBarSwitchIntervalPersists() {
        var settings = store.load()
        settings.statusBarSwitchIntervalSeconds = 8

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.statusBarSwitchIntervalSeconds, 8)
    }

    func testStatusBarClockRotatesAcrossOrderedClockEntries() {
        var settings = store.load()
        settings.replaceClockEntries([
            ClockEntry.custom(identifier: "America/Los_Angeles")!,
            ClockEntry.custom(identifier: "Asia/Shanghai")!
        ])

        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(settings.statusBarClock(at: start, switchInterval: 5).identifier, "America/Los_Angeles")
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(4.9), switchInterval: 5).identifier, "America/Los_Angeles")
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(5), switchInterval: 5).identifier, "Asia/Shanghai")
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(10), switchInterval: 5).identifier, "America/Los_Angeles")

        settings.statusBarSwitchIntervalSeconds = 3
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(2.9)).identifier, "America/Los_Angeles")
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(3)).identifier, "Asia/Shanghai")
    }

    func testSystemClockUsesCompactTimeZoneIdentifier() {
        let settings = store.load()
        let systemClock = settings.clockTimeZones.first

        XCTAssertNotEqual(systemClock?.statusBarTitle, "LOCAL")
        XCTAssertFalse(systemClock?.statusBarTitle.isEmpty ?? true)
    }

    func testKnownTimeZonesExposeLocalCountryFlags() {
        XCTAssertEqual(TimeZoneCatalog.flag(for: "America/Los_Angeles"), "🇺🇸")
        XCTAssertEqual(TimeZoneCatalog.flag(for: "Asia/Shanghai"), "🇨🇳")
        XCTAssertEqual(TimeZoneCatalog.flag(for: "Europe/London"), "🇬🇧")
    }

    func testLunarDisplayDefaultsOnForChineseCultureRegionsAndOffElsewhere() {
        let cnDefaults = UserDefaults(suiteName: "\(suiteName!).cn")!
        let usDefaults = UserDefaults(suiteName: "\(suiteName!).us")!
        defer {
            cnDefaults.removePersistentDomain(forName: "\(suiteName!).cn")
            usDefaults.removePersistentDomain(forName: "\(suiteName!).us")
        }

        XCTAssertTrue(SettingsStore(defaults: cnDefaults, regionCodeProvider: { "CN" }).load().showsLunarCalendar)
        XCTAssertFalse(SettingsStore(defaults: usDefaults, regionCodeProvider: { "US" }).load().showsLunarCalendar)
    }

    func testDerivedLunarDefaultPersistsAfterRegionChanges() {
        let first = SettingsStore(defaults: defaults, regionCodeProvider: { "CN" }).load()
        let afterRegionChange = SettingsStore(defaults: defaults, regionCodeProvider: { "US" }).load()

        XCTAssertTrue(first.showsLunarCalendar)
        XCTAssertTrue(afterRegionChange.showsLunarCalendar)
    }

    func testLunarDisplayAndAllDayPolicyPersist() {
        var settings = store.load()
        settings.showsLunarCalendar = true
        settings.allDayEventDatePolicy = .overviewTimeZone

        store.save(settings)
        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertTrue(reloaded.showsLunarCalendar)
        XCTAssertEqual(reloaded.allDayEventDatePolicy, .overviewTimeZone)
    }

    func testLunarDisplayAndAllDayPolicyRoundTripAsPortableFields() {
        var source = store.load()
        source.showsLunarCalendar = true
        source.allDayEventDatePolicy = .overviewTimeZone
        var destination = store.load()

        XCTAssertTrue(destination.applyPortableValue(
            source.portableValue(for: .showsLunarCalendar),
            for: .showsLunarCalendar
        ))
        XCTAssertTrue(destination.applyPortableValue(
            source.portableValue(for: .allDayEventDatePolicy),
            for: .allDayEventDatePolicy
        ))
        XCTAssertTrue(destination.showsLunarCalendar)
        XCTAssertEqual(destination.allDayEventDatePolicy, .overviewTimeZone)
    }
}
