import Foundation
import XCTest
@testable import TouchMacer

final class ClockEntryAndCarouselTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TouchMacerTests.ClockEntryAndCarouselTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testClockEntryNormalizationPreservesFirstValidOrderedIdentityAndNonEmptyInvariant() {
        let newYork = ClockEntry.custom(identifier: "America/New_York")!
        let invalid = ClockEntry(id: "Not/AZone", customLabel: "Ignored")
        let settings = makeSettings(clockEntries: [
            invalid,
            ClockEntry.system(customLabel: "  Here  "),
            ClockEntry.system(customLabel: "Duplicate"),
            newYork,
            newYork
        ])

        XCTAssertEqual(settings.clockEntries, [
            ClockEntry.system(customLabel: "Here"),
            newYork
        ])

        let fallback = makeSettings(clockEntries: [invalid])
        XCTAssertEqual(fallback.clockEntries, [.system()])
    }

    func testClockOperationsRejectFinalRemovalAndSupportRemoveReaddAndMove() {
        var settings = makeSettings(clockEntries: [.system()])

        XCTAssertFalse(settings.removeClock(id: ClockEntry.systemID))
        XCTAssertTrue(settings.addClock(identifier: "America/New_York"))
        XCTAssertTrue(settings.removeClock(id: ClockEntry.systemID))
        XCTAssertTrue(settings.addSystemClock())
        XCTAssertTrue(settings.moveClock(id: ClockEntry.systemID, by: -1))

        XCTAssertEqual(settings.clockEntries.map(\.id), [ClockEntry.systemID, "America/New_York"])
    }

    func testCustomLabelUsesTrimmedDisplayValueAndFallsBackToCatalogTitleWhenCleared() {
        var settings = makeSettings(clockEntries: [ClockEntry.custom(identifier: "Asia/Tokyo")!])

        XCTAssertTrue(settings.updateClockLabel(id: "Asia/Tokyo", label: "  Work  "))
        XCTAssertEqual(settings.clockTimeZones.first?.title, "Work")
        XCTAssertTrue(settings.updateClockLabel(id: "Asia/Tokyo", label: "   "))
        XCTAssertEqual(
            settings.clockTimeZones.first?.title,
            TimeZoneCatalog.shortTitle(for: "Asia/Tokyo")
        )
    }

    func testClockEntriesPersistOrderAndLabelsAcrossSettingsStoreRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        settings.replaceClockEntries([
            ClockEntry.custom(identifier: "Asia/Tokyo", customLabel: "Tokyo desk")!,
            .system(),
            ClockEntry.custom(identifier: "America/New_York")!
        ])

        store.save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.clockEntries, settings.clockEntries)
        XCTAssertEqual(reloaded.displayTimeZone.identifier, "Asia/Tokyo")
    }

    func testRotationUsesOrderedClockEntriesRatherThanTimeZoneIdentifiers() {
        let settings = makeSettings(clockEntries: [
            ClockEntry.custom(identifier: "Asia/Tokyo")!,
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Europe/London")!
        ])
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(settings.statusBarClock(at: start, switchInterval: 10).id, "Asia/Tokyo")
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(10), switchInterval: 10).id, "America/New_York")
        XCTAssertEqual(settings.statusBarClock(at: start.addingTimeInterval(20), switchInterval: 10).id, "Europe/London")
    }

    func testManualStatusClockPersistsAcrossAutomaticRotationIntervalsUntilCleared() {
        let settings = makeSettings(clockEntries: [
            ClockEntry.custom(identifier: "Asia/Tokyo")!,
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Europe/London")!
        ])
        let dates = [
            Date(timeIntervalSinceReferenceDate: 0),
            Date(timeIntervalSinceReferenceDate: 5),
            Date(timeIntervalSinceReferenceDate: 10)
        ]

        for date in dates {
            XCTAssertEqual(
                StatusClockResolver.clock(in: settings, manualClockID: "America/New_York", at: date).id,
                "America/New_York"
            )
        }

        XCTAssertEqual(StatusClockResolver.clock(in: settings, manualClockID: nil, at: dates[0]).id, "Asia/Tokyo")
        XCTAssertEqual(StatusClockResolver.clock(in: settings, manualClockID: nil, at: dates[1]).id, "America/New_York")
        XCTAssertEqual(StatusClockResolver.clock(in: settings, manualClockID: nil, at: dates[2]).id, "Europe/London")
    }

    func testTemporaryScrollSelectionExpiresAfterOneCompleteRotationInterval() {
        let settings = makeSettings(clockEntries: [
            ClockEntry.custom(identifier: "Asia/Tokyo")!,
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Europe/London")!
        ])
        let selectedAt = Date(timeIntervalSinceReferenceDate: 0)
        let selection = TemporaryClockSelection(
            clockID: "Europe/London",
            selectedAt: selectedAt,
            duration: settings.statusBarSwitchIntervalSeconds
        )

        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: nil,
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(4.999)
            ).id,
            "Europe/London"
        )
        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: nil,
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(5)
            ).id,
            "Asia/Tokyo"
        )
        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: nil,
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(10)
            ).id,
            "America/New_York"
        )
    }

    func testTemporaryScrollSelectionReturnsToPersistentMenuSelectionWhenExpired() {
        let settings = makeSettings(clockEntries: [
            ClockEntry.custom(identifier: "Asia/Tokyo")!,
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Europe/London")!
        ])
        let selectedAt = Date(timeIntervalSinceReferenceDate: 0)
        let selection = TemporaryClockSelection(
            clockID: "America/New_York",
            selectedAt: selectedAt,
            duration: settings.statusBarSwitchIntervalSeconds
        )

        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: "Europe/London",
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(4.999)
            ).id,
            "America/New_York"
        )
        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: "Europe/London",
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(5)
            ).id,
            "Europe/London"
        )
    }

    func testLatestScrollSelectionRestartsTheCompleteTemporaryInterval() {
        let firstSelectionDate = Date(timeIntervalSinceReferenceDate: 0)
        let secondSelectionDate = firstSelectionDate.addingTimeInterval(3)
        var state = StatusClockSelectionState()

        state.selectTemporarily(
            clockID: "America/New_York",
            at: firstSelectionDate,
            duration: 5
        )
        state.selectTemporarily(
            clockID: "Europe/London",
            at: secondSelectionDate,
            duration: 5
        )

        XCTAssertEqual(state.temporarySelection?.clockID, "Europe/London")
        XCTAssertEqual(
            state.temporarySelection?.expiresAt,
            secondSelectionDate.addingTimeInterval(5)
        )
        XCTAssertTrue(
            state.temporarySelection?.isActive(
                at: secondSelectionDate.addingTimeInterval(4.999)
            ) == true
        )
    }

    func testMenuSelectionAndAutoRotateClearTemporaryScrollState() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        var state = StatusClockSelectionState()
        state.selectTemporarily(clockID: "America/New_York", at: date, duration: 5)

        state.selectPersistently(clockID: "Europe/London")

        XCTAssertEqual(state.persistentClockID, "Europe/London")
        XCTAssertNil(state.temporarySelection)

        state.selectTemporarily(clockID: "Asia/Tokyo", at: date, duration: 5)
        state.resumeAutomaticRotation()

        XCTAssertNil(state.persistentClockID)
        XCTAssertNil(state.temporarySelection)
    }

    func testUnavailableClockSelectionsAreClearedTogether() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        var state = StatusClockSelectionState()
        state.selectPersistently(clockID: "Europe/London")
        state.selectTemporarily(clockID: "America/New_York", at: date, duration: 5)

        state.removeUnavailableClockIDs(validClockIDs: ["Asia/Tokyo"])

        XCTAssertNil(state.persistentClockID)
        XCTAssertNil(state.temporarySelection)
    }

    func testActiveSelectionKeepsCapturedDurationThenUsesLatestAutomaticInterval() {
        var settings = makeSettings(clockEntries: [
            ClockEntry.custom(identifier: "Asia/Tokyo")!,
            ClockEntry.custom(identifier: "America/New_York")!,
            ClockEntry.custom(identifier: "Europe/London")!
        ])
        let selectedAt = Date(timeIntervalSinceReferenceDate: 0)
        let selection = TemporaryClockSelection(
            clockID: "Europe/London",
            selectedAt: selectedAt,
            duration: settings.statusBarSwitchIntervalSeconds
        )
        settings.statusBarSwitchIntervalSeconds = 2

        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: nil,
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(4.999)
            ).id,
            "Europe/London"
        )
        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: nil,
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(5)
            ).id,
            "Asia/Tokyo"
        )
        XCTAssertEqual(
            StatusClockResolver.clock(
                in: settings,
                manualClockID: nil,
                temporarySelection: selection,
                at: selectedAt.addingTimeInterval(7)
            ).id,
            "America/New_York"
        )
    }

    func testCarouselNavigationWrapsFromTheManualSelectionInBothDirections() {
        let clocks = [
            ClockTimeZone.custom(identifier: "America/New_York")!,
            ClockTimeZone.custom(identifier: "Europe/London")!,
            ClockTimeZone.custom(identifier: "Asia/Tokyo")!
        ]

        XCTAssertEqual(
            ClockCarouselNavigator.adjacentClockID(in: clocks, currentID: "Asia/Tokyo", step: 1),
            "America/New_York"
        )
        XCTAssertEqual(
            ClockCarouselNavigator.adjacentClockID(in: clocks, currentID: "America/New_York", step: -1),
            "Asia/Tokyo"
        )
        XCTAssertEqual(
            ClockCarouselNavigator.adjacentClockID(in: clocks, currentID: "Europe/London", step: 1),
            "Asia/Tokyo"
        )
    }

    private func makeSettings(clockEntries: [ClockEntry]) -> AppSettings {
        AppSettings(
            clockEntries: clockEntries,
            statusBarSwitchIntervalSeconds: 5,
            appearanceMode: .system,
            appearanceTimeZoneID: "UTC",
            appliesSystemAppearance: false,
            overviewTimeZoneID: "UTC",
            calendarWeekStartDay: .monday,
            calendarSelectionMode: .all,
            selectedCalendarIDs: [],
            pinnedQuickActions: []
        )
    }
}
