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


    func testCalendarWeekStartDayPersistsAcrossSaveAndLoad() {
        var settings = store.load()
        settings.calendarWeekStartDay = .sunday

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.calendarWeekStartDay, .sunday)
    }

    func testQuickEventDraftRoundsInExplicitKathmanduTimeZone() throws {
        let kathmandu = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kathmandu
        let requestedStart = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: kathmandu,
            year: 2026,
            month: 1,
            day: 15,
            hour: 9,
            minute: 37,
            second: 42
        )))
        let expectedStart = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: kathmandu,
            year: 2026,
            month: 1,
            day: 15,
            hour: 10,
            minute: 0,
            second: 0
        )))

        let draft = QuickEventDraft(
            startDate: requestedStart, calendarID: "primary", timeZone: kathmandu)

        XCTAssertEqual(draft.startDate, expectedStart)
        XCTAssertEqual(draft.endDate, expectedStart.addingTimeInterval(60 * 60))
    }

    func testLegacyOverviewSelectionWinsOverAppearanceAndCarouselOrder() {
        defaults.set("Europe/London", forKey: "appearanceTimeZoneID")
        defaults.set("Pacific/Honolulu", forKey: "overviewTimeZoneID")
        var settings = store.load()
        settings.replaceClockEntries([
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Asia/Shanghai")!
        ])

        store.save(settings)
        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.anchorTimeZoneID, "Pacific/Honolulu")
        XCTAssertEqual(reloaded.anchorTimeZone.identifier, "Pacific/Honolulu")
        XCTAssertEqual(reloaded.clockEntries.map(\.id), ["America/New_York", "Asia/Shanghai"])
        XCTAssertNil(defaults.string(forKey: "appearanceTimeZoneID"))
    }

    func testMissingAnchorSelectionFallsBackToSystemRatherThanFirstCarouselClock() {
        var settings = store.load()
        let otherZones = ["Asia/Shanghai", "Europe/London", "Pacific/Honolulu"]
            .filter { $0 != TimeZone.autoupdatingCurrent.identifier }
        settings.replaceClockEntries(otherZones.compactMap { ClockEntry.custom(identifier: $0) })
        store.save(settings)
        defaults.removeObject(forKey: "overviewTimeZoneID")

        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.anchorTimeZoneID, TimeZone.autoupdatingCurrent.identifier)
        XCTAssertEqual(reloaded.anchorTimeZone.identifier, TimeZone.autoupdatingCurrent.identifier)
        XCTAssertNotEqual(reloaded.anchorTimeZoneID, reloaded.clockEntries.first?.id)
    }

    func testUnavailableAnchorWarnsAndDoesNotBorrowCarouselZone() {
        var settings = store.load()
        settings.anchorTimeZoneID = "Unavailable/Anchor"
        let otherZone = ["Asia/Shanghai", "Pacific/Honolulu"].first {
            $0 != TimeZone.autoupdatingCurrent.identifier
        }!
        settings.replaceClockEntries([ClockEntry.custom(identifier: otherZone)!])

        XCTAssertTrue(settings.isAnchorTimeZoneUnavailable)
        XCTAssertEqual(settings.anchorTimeZone.identifier, TimeZone.autoupdatingCurrent.identifier)
        XCTAssertNotEqual(settings.anchorTimeZone.identifier, settings.clockTimeZones.first?.identifier)
    }

    func testQuickEventDraftKeepsSecondAutumnHourAndRoundsForward() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let requested = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T09:30:00Z"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        let draft = QuickEventDraft(startDate: requested, calendarID: nil, timeZone: zone)

        XCTAssertEqual(draft.startDate, expected)
        XCTAssertEqual(draft.endDate, expected.addingTimeInterval(3_600))
    }


    func testStatusBarSwitchIntervalPersists() {
        var settings = store.load()
        settings.statusBarSwitchIntervalSeconds = 8

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.statusBarSwitchIntervalSeconds, 8)
    }


    func testMenuBarFormatPersistsSelectedStatusItemIcon() {
        var settings = store.load()
        var format = MenuBarFormatSettings.compatibilityDefault
        format.statusItemContent = .icon
        format.statusItemIcon = .sparkles
        settings.menuBarFormat = format

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load().menuBarFormat
        XCTAssertEqual(reloaded.statusItemContent, .icon)
        XCTAssertEqual(reloaded.statusItemIcon, .sparkles)
    }

    func testLegacyMenuBarFormatPayloadWithoutStatusItemFieldsUsesClockAndAppIcon() throws {
        let legacyPayload = """
        {
          "mode": "advanced",
          "clockCycle": "twelveHour",
          "showsSeconds": false,
          "dateStyle": "iso",
          "weekdayStyle": "full",
          "segmentOrder": "timeThenDate",
          "advancedDatePattern": "yyyy-MM-dd",
          "advancedTimePattern": "h:mm a"
        }
        """

        let decoded = try JSONDecoder().decode(
            MenuBarFormatSettings.self,
            from: try XCTUnwrap(legacyPayload.data(using: .utf8))
        )

        XCTAssertEqual(decoded.mode, .advanced)
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
