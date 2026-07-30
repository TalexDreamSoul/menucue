import Foundation
import XCTest
@testable import MenuCue

final class CalendarPresentationTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let honolulu = TimeZone(identifier: "Pacific/Honolulu")!

    func testCivilDateKeyRoundTripsInExplicitTimeZone() throws {
        let date = try makeDate(2024, 2, 10, 0, 30, timeZone: shanghai)
        let key = CivilDateKey(date: date, timeZone: shanghai)

        XCTAssertEqual(key, CivilDateKey(year: 2024, month: 2, day: 10))
        XCTAssertEqual(key.description, "2024-02-10")
        XCTAssertEqual(CivilDateKey(date: try XCTUnwrap(key.date(in: shanghai)), timeZone: shanghai), key)
    }

    func testCivilDateKeyCodableAndExtremeOffsetBoundariesAreStable() throws {
        let key = CivilDateKey(year: 2024, month: 2, day: 10)
        let encoded = try JSONEncoder().encode(key)
        XCTAssertEqual(try JSONDecoder().decode(CivilDateKey.self, from: encoded), key)

        let instant = try makeDate(2024, 2, 10, 1, 0, timeZone: utc)
        let utcPlusFourteen = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let utcMinusTwelve = try XCTUnwrap(TimeZone(secondsFromGMT: -12 * 3_600))
        XCTAssertEqual(
            CivilDateKey(date: instant, timeZone: utcPlusFourteen),
            CivilDateKey(year: 2024, month: 2, day: 10)
        )
        XCTAssertEqual(
            CivilDateKey(date: instant, timeZone: utcMinusTwelve),
            CivilDateKey(year: 2024, month: 2, day: 9)
        )
    }

    func testMonthBuilderAlwaysProducesFortyTwoDaysUsingConfiguredWeekStart() throws {
        let month = try makeDate(2026, 2, 15, 12, 0, timeZone: utc)
        let days = CalendarMonthBuilder(
            timeZone: utc,
            weekStartDay: .monday,
            showsLunarCalendar: false,
            allDayEventDatePolicy: .preserveSource,
            solarTerms: nil
        ).days(monthDate: month, selectedDate: month, now: month, events: [])

        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(days.first?.civilDate, CivilDateKey(year: 2026, month: 1, day: 26))
        XCTAssertEqual(days.last?.civilDate, CivilDateKey(year: 2026, month: 3, day: 8))
        XCTAssertEqual(days.filter(\.isInMonth).count, 28)
    }

    func testMonthBuilderHandlesLeapDayDSTAndBothWeekStarts() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let leapMonth = try makeDate(2024, 2, 15, 12, 0, timeZone: losAngeles)
        let dstMonth = try makeDate(2024, 3, 15, 12, 0, timeZone: losAngeles)

        for weekStart: WeekStartDay in [.sunday, .monday] {
            let builder = CalendarMonthBuilder(
                timeZone: losAngeles,
                weekStartDay: weekStart,
                showsLunarCalendar: false,
                allDayEventDatePolicy: .preserveSource,
                solarTerms: nil
            )
            let leapDays = builder.days(
                monthDate: leapMonth,
                selectedDate: leapMonth,
                now: leapMonth,
                events: []
            )
            let dstDays = builder.days(
                monthDate: dstMonth,
                selectedDate: dstMonth,
                now: dstMonth,
                events: []
            )

            XCTAssertEqual(leapDays.filter(\.isInMonth).count, 29)
            XCTAssertEqual(dstDays.count, 42)
            XCTAssertEqual(Set(dstDays.map(\.civilDate)).count, 42)
            for pair in zip(dstDays, dstDays.dropFirst()) {
                XCTAssertEqual(pair.0.civilDate.addingDays(1), pair.1.civilDate)
            }
        }
    }

    func testLunarProviderReportsSpringFestivalAndLeapMonthWithoutDuplicatingFestival() throws {
        let provider = LunarDateProvider(timeZone: shanghai, locale: Locale(identifier: "zh-Hans"))
        let springFestival = try XCTUnwrap(provider.info(for: makeDate(2024, 2, 10, 12, 0, timeZone: shanghai)))
        let leapMonth = try XCTUnwrap(provider.info(for: makeDate(2023, 3, 22, 12, 0, timeZone: shanghai)))

        XCTAssertEqual(springFestival.month, 1)
        XCTAssertEqual(springFestival.day, 1)
        XCTAssertFalse(springFestival.isLeapMonth)
        XCTAssertEqual(springFestival.festival, .springFestival)
        XCTAssertEqual(leapMonth.month, 2)
        XCTAssertEqual(leapMonth.day, 1)
        XCTAssertTrue(leapMonth.isLeapMonth)
        XCTAssertNil(leapMonth.festival)
    }

    func testLunarProviderUsesOverviewTimeZoneAtSpringFestivalBoundary() throws {
        let instant = try makeDate(2024, 2, 10, 0, 30, timeZone: shanghai)
        let shanghaiProvider = LunarDateProvider(
            timeZone: shanghai,
            locale: Locale(identifier: "zh-Hans")
        )
        let honoluluProvider = LunarDateProvider(
            timeZone: honolulu,
            locale: Locale(identifier: "zh-Hans")
        )

        XCTAssertEqual(shanghaiProvider.info(for: instant)?.festival, .springFestival)
        XCTAssertNotEqual(honoluluProvider.info(for: instant)?.festival, .springFestival)
    }

    func testTraditionalFestivalResolverFindsDynamicNewYearsEve() throws {
        let provider = LunarDateProvider(timeZone: shanghai, locale: Locale(identifier: "zh-Hans"))
        let eve = try XCTUnwrap(provider.info(for: makeDate(2024, 2, 9, 12, 0, timeZone: shanghai)))

        XCTAssertEqual(eve.festival, .newYearsEve)
    }

    func testAllTwelveTraditionalFestivalsResolveOnGoldenDates() throws {
        let provider = LunarDateProvider(timeZone: shanghai, locale: Locale(identifier: "zh-Hans"))
        let cases: [(Int, Int, Int, TraditionalFestival)] = [
            (2024, 2, 10, .springFestival),
            (2024, 2, 24, .lanternFestival),
            (2024, 3, 11, .longtaitou),
            (2024, 6, 10, .dragonBoat),
            (2024, 8, 10, .qixi),
            (2024, 8, 18, .ghostFestival),
            (2024, 9, 17, .midAutumn),
            (2024, 10, 11, .doubleNinth),
            (2024, 11, 1, .winterClothes),
            (2024, 11, 15, .xiayuan),
            (2025, 1, 7, .laba),
            (2024, 2, 9, .newYearsEve),
        ]

        for (year, month, day, festival) in cases {
            let date = try makeDate(year, month, day, 12, 0, timeZone: shanghai)
            XCTAssertEqual(provider.info(for: date)?.festival, festival, "\(year)-\(month)-\(day)")
        }
    }

    func testNewYearsEveSupportsTwentyNineDayFinalLunarMonth() throws {
        let provider = LunarDateProvider(timeZone: shanghai, locale: Locale(identifier: "zh-Hans"))
        let date = try makeDate(2025, 1, 28, 12, 0, timeZone: shanghai)
        let info = try XCTUnwrap(provider.info(for: date))

        XCTAssertEqual(info.month, 12)
        XCTAssertEqual(info.day, 29)
        XCTAssertEqual(info.festival, .newYearsEve)
    }

    func testBundledSolarTermsCoverEveryYearAndStayOnChinaCivilDate() throws {
        let store = try XCTUnwrap(SolarTermStore.bundled)

        XCTAssertEqual(store.coveredYears, 1901...2100)
        XCTAssertTrue(store.hasExactlyTwentyFourTermsPerYear)
        XCTAssertEqual(store.resourceSchemaVersion, 1)
        XCTAssertEqual(
            store.sourceRevision,
            "7160e561bf6d13c68678e12585c768616463f5e4"
        )
        XCTAssertEqual(store.term(on: CivilDateKey(year: 2024, month: 4, day: 4)), .qingming)

        let shanghaiDate = try makeDate(2024, 4, 4, 12, 0, timeZone: shanghai)
        let honoluluDate = try makeDate(2024, 4, 4, 12, 0, timeZone: honolulu)
        XCTAssertEqual(CivilDateKey(date: shanghaiDate, timeZone: shanghai), CivilDateKey(year: 2024, month: 4, day: 4))
        XCTAssertEqual(CivilDateKey(date: honoluluDate, timeZone: honolulu), CivilDateKey(year: 2024, month: 4, day: 4))
        XCTAssertEqual(store.term(on: CivilDateKey(date: honoluluDate, timeZone: honolulu)), .qingming)
        XCTAssertNil(store.term(on: CivilDateKey(year: 1900, month: 4, day: 5)))
        XCTAssertNil(store.term(on: CivilDateKey(year: 2101, month: 4, day: 5)))
    }

    func testSolarTermStoreRejectsResourceChecksumMismatch() throws {
        let metadata = Data(
            #"{"schemaVersion":1,"source":"test","sourceRevision":"test","sha256":"0000"}"#.utf8
        )

        XCTAssertThrowsError(
            try SolarTermStore(data: Data("{}".utf8), metadataData: metadata)
        ) { error in
            guard case SolarTermStoreError.checksumMismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
    }

    func testEventQueryPlannerPadsVisibleGridByExactlyTwoCivilDays() throws {
        let month = try makeDate(2026, 2, 15, 12, 0, timeZone: utc)
        let ranges = CalendarEventQueryPlanner.ranges(
            visibleMonthDate: month,
            now: month,
            timeZone: utc,
            weekStartDay: .monday,
            daysAhead: 14
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(CivilDateKey(date: ranges[0].start, timeZone: utc), CivilDateKey(year: 2026, month: 1, day: 24))
        XCTAssertEqual(CivilDateKey(date: ranges[0].end, timeZone: utc), CivilDateKey(year: 2026, month: 3, day: 11))
    }

    func testTimedEventOccupiesEveryIntersectingCivilDayButNotExclusiveEndMidnight() throws {
        let start = try makeDate(2024, 3, 9, 23, 30, timeZone: shanghai)
        let end = try makeDate(2024, 3, 11, 0, 0, timeZone: shanghai)
        let event = event(start: start, end: end)

        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: event,
                timeZone: shanghai,
                allDayPolicy: .preserveSource
            ),
            [
                CivilDateKey(year: 2024, month: 3, day: 9),
                CivilDateKey(year: 2024, month: 3, day: 10),
            ]
        )
    }

    func testAllDayEventCanPreserveSourceCivilDateOrRegroupInOverviewTimeZone() throws {
        let start = try makeDate(2024, 2, 10, 0, 0, timeZone: shanghai)
        let end = try makeDate(2024, 2, 11, 0, 0, timeZone: shanghai)
        let event = CalendarEventInfo(
            id: "all-day",
            title: "Festival",
            calendarTitle: "Home",
            startDate: start,
            endDate: end,
            isAllDay: true,
            sourceStartCivilDate: CivilDateKey(year: 2024, month: 2, day: 10),
            sourceEndCivilDateExclusive: CivilDateKey(year: 2024, month: 2, day: 11)
        )

        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: event,
                timeZone: honolulu,
                allDayPolicy: .preserveSource
            ),
            [CivilDateKey(year: 2024, month: 2, day: 10)]
        )
        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: event,
                timeZone: honolulu,
                allDayPolicy: .overviewTimeZone
            ),
            [
                CivilDateKey(year: 2024, month: 2, day: 9),
                CivilDateKey(year: 2024, month: 2, day: 10),
            ]
        )
    }

    func testEventProjectionHandlesDSTAndZeroDuration() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try makeDate(2024, 3, 9, 23, 30, timeZone: losAngeles)
        let end = try makeDate(2024, 3, 11, 0, 0, timeZone: losAngeles)

        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: event(start: start, end: end),
                timeZone: losAngeles,
                allDayPolicy: .preserveSource
            ),
            [
                CivilDateKey(year: 2024, month: 3, day: 9),
                CivilDateKey(year: 2024, month: 3, day: 10),
            ]
        )
        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: event(start: start, end: start),
                timeZone: losAngeles,
                allDayPolicy: .preserveSource
            ),
            [CivilDateKey(year: 2024, month: 3, day: 9)]
        )
    }

    func testSubMillisecondCrossMidnightEventIncludesTheSecondCivilDate() throws {
        let start = try makeDate(2024, 3, 9, 23, 59, timeZone: utc)
        let midnight = try makeDate(2024, 3, 10, 0, 0, timeZone: utc)
        let end = midnight.addingTimeInterval(0.0005)

        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: event(start: start, end: end),
                timeZone: utc,
                allDayPolicy: .preserveSource
            ),
            [
                CivilDateKey(year: 2024, month: 3, day: 9),
                CivilDateKey(year: 2024, month: 3, day: 10),
            ]
        )
    }

    func testAllDayPreservationSurvivesMaximumOverviewOffsetDifference() throws {
        let utcPlusFourteen = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let utcMinusTwelve = try XCTUnwrap(TimeZone(secondsFromGMT: -12 * 3_600))
        let start = try makeDate(2024, 2, 10, 0, 0, timeZone: utcPlusFourteen)
        let end = try makeDate(2024, 2, 11, 0, 0, timeZone: utcPlusFourteen)
        let allDay = CalendarEventInfo(
            id: "extreme-all-day",
            title: "Event",
            calendarTitle: "Calendar",
            startDate: start,
            endDate: end,
            isAllDay: true,
            sourceStartCivilDate: CivilDateKey(year: 2024, month: 2, day: 10),
            sourceEndCivilDateExclusive: CivilDateKey(year: 2024, month: 2, day: 11)
        )

        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: allDay,
                timeZone: utcMinusTwelve,
                allDayPolicy: .preserveSource
            ),
            [CivilDateKey(year: 2024, month: 2, day: 10)]
        )
        XCTAssertEqual(
            EventDateProjector.civilDates(
                for: allDay,
                timeZone: utcMinusTwelve,
                allDayPolicy: .overviewTimeZone
            ),
            [
                CivilDateKey(year: 2024, month: 2, day: 8),
                CivilDateKey(year: 2024, month: 2, day: 9),
            ]
        )
    }

    func testAgendaFiltersAfterCivilProjectionForExtremeAllDayOffsets() throws {
        let utcPlusFourteen = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let utcMinusTwelve = try XCTUnwrap(TimeZone(secondsFromGMT: -12 * 3_600))
        let start = try makeDate(2024, 2, 10, 0, 0, timeZone: utcPlusFourteen)
        let end = try makeDate(2024, 2, 11, 0, 0, timeZone: utcPlusFourteen)
        let now = try makeDate(2024, 2, 9, 23, 0, timeZone: utcMinusTwelve)
        XCTAssertLessThan(end, now)
        let allDay = CalendarEventInfo(
            id: "future-civil-day",
            title: "Event",
            calendarTitle: "Calendar",
            startDate: start,
            endDate: end,
            isAllDay: true,
            sourceStartCivilDate: CivilDateKey(year: 2024, month: 2, day: 10),
            sourceEndCivilDateExclusive: CivilDateKey(year: 2024, month: 2, day: 11)
        )
        let endedTimed = event(start: start, end: now)

        let grouped = AgendaEventProjector.eventsByCivilDate(
            [allDay, endedTimed],
            now: now,
            timeZone: utcMinusTwelve,
            allDayPolicy: .preserveSource
        )

        XCTAssertEqual(
            grouped[CivilDateKey(year: 2024, month: 2, day: 10)],
            [allDay]
        )
        XCTAssertFalse(grouped.values.flatMap { $0 }.contains(endedTimed))
    }

    func testRecurringOccurrencesReceiveDistinctStablePresentationIDs() throws {
        let firstStart = try makeDate(2024, 2, 10, 9, 0, timeZone: utc)
        let secondStart = try makeDate(2024, 2, 11, 9, 0, timeZone: utc)
        let firstID = CalendarEventOccurrenceIdentifier.make(
            eventIdentifier: "shared-series-id",
            calendarItemIdentifier: "calendar-item",
            startDate: firstStart
        )

        XCTAssertEqual(
            firstID,
            CalendarEventOccurrenceIdentifier.make(
                eventIdentifier: "shared-series-id",
                calendarItemIdentifier: "calendar-item",
                startDate: firstStart
            )
        )
        XCTAssertNotEqual(
            firstID,
            CalendarEventOccurrenceIdentifier.make(
                eventIdentifier: "shared-series-id",
                calendarItemIdentifier: "calendar-item",
                startDate: secondStart
            )
        )
    }

    private func event(start: Date, end: Date) -> CalendarEventInfo {
        CalendarEventInfo(
            id: UUID().uuidString,
            title: "Event",
            calendarTitle: "Calendar",
            startDate: start,
            endDate: end,
            isAllDay: false
        )
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
