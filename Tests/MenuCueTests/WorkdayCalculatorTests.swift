import Foundation
import XCTest
@testable import MenuCue

/// The published schedules are the whole point of this type, so the golden cases below
/// are the notices themselves: a Spring Festival month where work moves onto both
/// flanking Saturdays, a month with no holiday at all, and the National Day weeks.
final class WorkdayCalculatorTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func testSpringFestivalMonthMovesWorkOntoTheFlankingSaturdays() throws {
        let calendar = gregorian(in: shanghai)

        XCTAssertTrue(isWorkday(2026, 2, 14, calendar))
        XCTAssertTrue(isWorkday(2026, 2, 28, calendar))
        for day in 15...23 {
            XCTAssertFalse(
                isWorkday(2026, 2, day, calendar),
                "2026-02-\(day) is inside the Spring Festival break"
            )
        }

        let stats = try monthStats(2026, 2, calendar: calendar, now: date(2026, 2, 1, calendar))
        // 20 Mon–Fri days, minus the six weekdays inside the break, plus two Saturdays.
        XCTAssertEqual(stats.workdays, 16)
        XCTAssertEqual(stats.restDays, 12)
        XCTAssertFalse(stats.isEstimated)
    }

    func testMonthWithoutHolidaysIsJustItsWeekdays() throws {
        let calendar = gregorian(in: shanghai)
        let stats = try monthStats(2026, 8, calendar: calendar, now: date(2027, 1, 1, calendar))

        XCTAssertEqual(stats.workdays, 21)
        XCTAssertEqual(stats.restDays, 10)
        XCTAssertFalse(stats.containsToday)
    }

    func testNationalDayWeekAndItsMakeupSaturday() throws {
        let calendar = gregorian(in: shanghai)

        for day in 1...7 {
            XCTAssertFalse(isWorkday(2026, 10, day, calendar), "2026-10-\(day) is National Day")
        }
        XCTAssertTrue(isWorkday(2026, 10, 10, calendar))

        let october = try monthStats(2026, 10, calendar: calendar, now: date(2026, 1, 1, calendar))
        // 22 Mon–Fri days, minus five inside the break, plus the makeup Saturday.
        XCTAssertEqual(october.workdays, 18)
        XCTAssertEqual(october.restDays, 13)
    }

    func testMakeupSundayBelongsToTheMonthItFallsIn() throws {
        let calendar = gregorian(in: shanghai)

        XCTAssertTrue(isWorkday(2026, 9, 20, calendar))
        for day in 25...27 {
            XCTAssertFalse(isWorkday(2026, 9, day, calendar), "2026-09-\(day) is Mid-Autumn")
        }

        let september = try monthStats(2026, 9, calendar: calendar, now: date(2026, 1, 1, calendar))
        // 22 Mon–Fri days, minus the Friday of Mid-Autumn, plus the makeup Sunday.
        XCTAssertEqual(september.workdays, 22)
        XCTAssertEqual(september.restDays, 8)
    }

    func testTwentyTwentyFiveNationalDayAndMidAutumnRunEightDays() throws {
        let calendar = gregorian(in: shanghai)

        for day in 1...8 {
            XCTAssertFalse(isWorkday(2025, 10, day, calendar), "2025-10-\(day) is the joint break")
        }
        XCTAssertTrue(isWorkday(2025, 9, 28, calendar))
        XCTAssertTrue(isWorkday(2025, 10, 11, calendar))

        let october = try monthStats(2025, 10, calendar: calendar, now: date(2025, 1, 1, calendar))
        // 23 Mon–Fri days, minus six inside the break, plus the makeup Saturday.
        XCTAssertEqual(october.workdays, 18)
        XCTAssertEqual(october.restDays, 13)
    }

    func testSpringFestivalStraddlingTwoMonthsIsCountedInBoth() throws {
        let calendar = gregorian(in: shanghai)

        XCTAssertTrue(isWorkday(2025, 1, 26, calendar))
        XCTAssertFalse(isWorkday(2025, 1, 28, calendar))
        XCTAssertFalse(isWorkday(2025, 2, 4, calendar))
        XCTAssertTrue(isWorkday(2025, 2, 5, calendar))
        XCTAssertTrue(isWorkday(2025, 2, 8, calendar))
    }

    func testYearWithoutAPublishedScheduleFallsBackToWeekdaysAndSaysSo() throws {
        let calendar = gregorian(in: shanghai)
        let now = date(2030, 1, 1, calendar)

        let statutory = try monthStats(2030, 10, calendar: calendar, now: now)
        let weekdaysOnly = try monthStats(
            2030, 10, scheme: .weekdaysOnly, calendar: calendar, now: now
        )

        XCTAssertTrue(statutory.isEstimated)
        XCTAssertFalse(weekdaysOnly.isEstimated)
        XCTAssertEqual(statutory.workdays, weekdaysOnly.workdays)
        XCTAssertTrue(isWorkday(2030, 10, 1, calendar), "no schedule means an ordinary Tuesday")
    }

    func testWeekdaysOnlySchemeIgnoresTheScheduleInACoveredYear() throws {
        let calendar = gregorian(in: shanghai)
        let now = date(2026, 1, 1, calendar)

        let statutory = try monthStats(2026, 2, calendar: calendar, now: now)
        let weekdaysOnly = try monthStats(
            2026, 2, scheme: .weekdaysOnly, calendar: calendar, now: now
        )

        XCTAssertEqual(statutory.workdays, 16)
        XCTAssertEqual(weekdaysOnly.workdays, 20)
        XCTAssertFalse(
            WorkdayCalculator.isWorkday(
                date(2026, 2, 14, calendar), scheme: .weekdaysOnly, calendar: calendar
            ),
            "the makeup Saturday is only a workday under the statutory scheme"
        )
    }

    func testTodayCountsAsRemainingRatherThanElapsed() throws {
        let calendar = gregorian(in: shanghai)
        // 2026-08-13 is a Thursday, with eight workdays behind it.
        let stats = try monthStats(2026, 8, calendar: calendar, now: date(2026, 8, 13, calendar))

        XCTAssertTrue(stats.containsToday)
        XCTAssertEqual(stats.elapsedWorkdays, 8)
        XCTAssertEqual(stats.remainingWorkdays, 13)
        XCTAssertEqual(stats.elapsedWorkdays + stats.remainingWorkdays, stats.workdays)
    }

    func testWeekStartDayDoesNotMoveTheCounts() throws {
        let sundayFirst = gregorian(in: shanghai, weekStart: .sunday)
        let mondayFirst = gregorian(in: shanghai, weekStart: .monday)
        let now = date(2026, 10, 15, mondayFirst)

        XCTAssertEqual(
            try monthStats(2026, 10, calendar: sundayFirst, now: now),
            try monthStats(2026, 10, calendar: mondayFirst, now: now)
        )
    }

    func testScheduleIsReadInTheSuppliedTimeZone() throws {
        let shanghaiCalendar = gregorian(in: shanghai)
        // 2026-10-01 00:30 in Shanghai is still 2026-09-30 in Honolulu, so the same
        // instant is a holiday in one calendar and an ordinary Wednesday in the other.
        let instant = try XCTUnwrap(shanghaiCalendar.date(from: DateComponents(
            calendar: shanghaiCalendar, timeZone: shanghai,
            year: 2026, month: 10, day: 1, hour: 0, minute: 30
        )))
        let honolulu = gregorian(in: try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu")))

        XCTAssertFalse(
            WorkdayCalculator.isWorkday(instant, scheme: .chineseStatutory, calendar: shanghaiCalendar)
        )
        XCTAssertTrue(
            WorkdayCalculator.isWorkday(instant, scheme: .chineseStatutory, calendar: honolulu)
        )
    }

    func testDayKindNamesTheHolidayItBelongsTo() throws {
        let calendar = gregorian(in: shanghai)

        XCTAssertEqual(
            ChineseHolidaySchedule.kind(of: date(2026, 10, 3, calendar), calendar: calendar),
            .holiday(.nationalDay)
        )
        XCTAssertEqual(
            ChineseHolidaySchedule.kind(of: date(2026, 2, 28, calendar), calendar: calendar),
            .makeupWorkday(.springFestival)
        )
        XCTAssertNil(ChineseHolidaySchedule.kind(of: date(2026, 3, 3, calendar), calendar: calendar))
        XCTAssertTrue(ChineseHolidaySchedule.coversYear(2025))
        XCTAssertTrue(ChineseHolidaySchedule.coversYear(2026))
        XCTAssertFalse(ChineseHolidaySchedule.coversYear(2027))
    }

    // MARK: - Helpers

    private func gregorian(
        in timeZone: TimeZone,
        weekStart: WeekStartDay = .monday
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = weekStart.firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )) ?? .distantPast
    }

    private func isWorkday(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Bool {
        WorkdayCalculator.isWorkday(
            date(year, month, day, calendar),
            scheme: .chineseStatutory,
            calendar: calendar
        )
    }

    private func monthStats(
        _ year: Int,
        _ month: Int,
        scheme: WorkdayScheme = .chineseStatutory,
        calendar: Calendar,
        now: Date
    ) throws -> MonthWorkdayStats {
        WorkdayCalculator.monthStats(
            month: date(year, month, 1, calendar),
            scheme: scheme,
            calendar: calendar,
            now: now
        )
    }
}
