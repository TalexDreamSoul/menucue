import Foundation
import XCTest
@testable import MenuCue

/// The wording asserts against `L10n` rather than against English text, so these tests
/// check *which* phrasing a distance picks — the catalogs themselves are guarded by
/// LocalizationCoverageTests and verify-localizations.
final class DateDistanceTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func testTheThreeNamedDaysAreNamed() {
        XCTAssertEqual(DateDistance(days: 0).localizedDescription, L10n.string("Today"))
        XCTAssertEqual(DateDistance(days: -1).localizedDescription, L10n.string("Yesterday"))
        XCTAssertEqual(DateDistance(days: 1).localizedDescription, L10n.string("Tomorrow"))
    }

    func testUnderAWeekStaysAPlainDayCount() {
        let ahead = DateDistance(days: 3)
        let behind = DateDistance(days: -3)

        XCTAssertFalse(ahead.showsWeekBreakdown)
        XCTAssertEqual(ahead.localizedDescription, L10n.format("In %d days", 3))
        XCTAssertEqual(behind.localizedDescription, L10n.format("%d days ago", 3))
        XCTAssertFalse(DateDistance(days: 6).showsWeekBreakdown)
    }

    func testSevenDaysIsWhereTheWeekConversionStarts() {
        let week = DateDistance(days: 7)

        XCTAssertTrue(week.showsWeekBreakdown)
        XCTAssertEqual(week.weeks, 1)
        XCTAssertEqual(week.remainderDays, 0)
        XCTAssertEqual(
            week.localizedDescription,
            L10n.format("%1$@ (%2$@)", L10n.format("In %d days", 7), L10n.format("%d week", 1))
        )
    }

    func testWholeWeeksDropTheDayRemainder() {
        let fortnight = DateDistance(days: 14)

        XCTAssertEqual(fortnight.weeks, 2)
        XCTAssertEqual(fortnight.remainderDays, 0)
        XCTAssertEqual(
            fortnight.localizedDescription,
            L10n.format("%1$@ (%2$@)", L10n.format("In %d days", 14), L10n.format("%d weeks", 2))
        )
    }

    func testPartialWeeksKeepBothHalves() {
        let ahead = DateDistance(days: 9)
        XCTAssertEqual(ahead.weeks, 1)
        XCTAssertEqual(ahead.remainderDays, 2)
        XCTAssertEqual(
            ahead.localizedDescription,
            L10n.format(
                "%1$@ (%2$@)",
                L10n.format("In %d days", 9),
                L10n.format("%d week %d days", 1, 2)
            )
        )

        let behind = DateDistance(days: -10)
        XCTAssertEqual(behind.magnitude, 10)
        XCTAssertEqual(behind.weeks, 1)
        XCTAssertEqual(behind.remainderDays, 3)
        XCTAssertEqual(
            behind.localizedDescription,
            L10n.format(
                "%1$@ (%2$@)",
                L10n.format("%d days ago", 10),
                L10n.format("%d week %d days", 1, 3)
            )
        )
    }

    func testSingularRemaindersUseSingularWording() {
        XCTAssertEqual(
            DateDistance(days: 8).localizedDescription,
            L10n.format(
                "%1$@ (%2$@)",
                L10n.format("In %d days", 8),
                L10n.format("%d week %d day", 1, 1)
            )
        )
        XCTAssertEqual(
            DateDistance(days: 15).localizedDescription,
            L10n.format(
                "%1$@ (%2$@)",
                L10n.format("In %d days", 15),
                L10n.format("%d weeks %d day", 2, 1)
            )
        )
    }

    func testDistanceCountsCalendarDaysNotElapsedHours() throws {
        let calendar = gregorian(in: shanghai)
        let lateTonight = try date(2026, 8, 13, hour: 23, minute: 50, calendar)
        let earlyTomorrow = try date(2026, 8, 14, hour: 0, minute: 10, calendar)
        let sameDayMorning = try date(2026, 8, 13, hour: 1, minute: 0, calendar)

        XCTAssertEqual(
            WorkdayCalculator.distance(from: lateTonight, to: earlyTomorrow, calendar: calendar),
            DateDistance(days: 1)
        )
        XCTAssertEqual(
            WorkdayCalculator.distance(from: lateTonight, to: sameDayMorning, calendar: calendar),
            DateDistance(days: 0)
        )
        XCTAssertEqual(
            WorkdayCalculator.distance(from: earlyTomorrow, to: lateTonight, calendar: calendar),
            DateDistance(days: -1)
        )
    }

    func testDistanceIsMeasuredInTheSuppliedTimeZone() throws {
        let shanghaiCalendar = gregorian(in: shanghai)
        let honoluluCalendar = gregorian(in: try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu")))
        let now = try date(2026, 8, 13, hour: 6, minute: 0, shanghaiCalendar)
        let target = try date(2026, 8, 14, hour: 6, minute: 0, shanghaiCalendar)

        XCTAssertEqual(
            WorkdayCalculator.distance(from: now, to: target, calendar: shanghaiCalendar).days, 1
        )
        // Both instants land on the previous civil day in Honolulu, one day apart still.
        XCTAssertEqual(
            WorkdayCalculator.distance(from: now, to: target, calendar: honoluluCalendar).days, 1
        )
        let elevenPM = try date(2026, 8, 13, hour: 23, minute: 0, shanghaiCalendar)
        XCTAssertEqual(
            WorkdayCalculator.distance(from: now, to: elevenPM, calendar: shanghaiCalendar).days, 0
        )
        // 06:00 and 23:00 in Shanghai straddle midnight in Honolulu.
        XCTAssertEqual(
            WorkdayCalculator.distance(from: now, to: elevenPM, calendar: honoluluCalendar).days, 1
        )
    }

    // MARK: - Helpers

    private func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = WeekStartDay.monday.firstWeekday
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int,
        minute: Int,
        _ calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
