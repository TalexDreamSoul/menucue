import Foundation

/// Which days count as work.
enum WorkdayScheme: String, CaseIterable, Codable, Identifiable {
    /// Monday–Friday, minus the statutory holidays and plus the weekends the State
    /// Council moves work onto.
    case chineseStatutory
    /// Monday–Friday, nothing else.
    case weekdaysOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chineseStatutory:
            return L10n.string("Chinese statutory holidays")
        case .weekdaysOnly:
            return L10n.string("Monday to Friday only")
        }
    }
}

/// The public holidays a Chinese work year is built around.
enum StatutoryHoliday: String, Equatable {
    case newYear
    case springFestival
    case qingming
    case labourDay
    case dragonBoat
    case midAutumn
    case nationalDay
    case nationalDayAndMidAutumn

    /// Resolved on read rather than stored in the tables below, so switching the app
    /// language relabels the days that are already on screen.
    var title: String {
        switch self {
        case .newYear: return L10n.string("New Year's Day")
        case .springFestival: return L10n.string("Spring Festival")
        case .qingming: return L10n.string("Qingming Festival")
        case .labourDay: return L10n.string("Labour Day")
        case .dragonBoat: return L10n.string("Dragon Boat Festival")
        case .midAutumn: return L10n.string("Mid-Autumn Festival")
        case .nationalDay: return L10n.string("National Day")
        case .nationalDayAndMidAutumn:
            return L10n.string("National Day & Mid-Autumn Festival")
        }
    }
}

/// The statutory holiday and make-up workday tables published each autumn by the
/// General Office of the State Council. Every year here is transcribed from the notice
/// that announced it:
///
/// - 2025 — 国办发明电〔2024〕12 号, published 2024-11-12
/// - 2026 — 国办发明电〔2025〕7 号, published 2025-11-04
///
/// A year is only ever right if it was copied from its own notice: the dates move every
/// year and cannot be derived. Years that have not been transcribed are simply absent,
/// and `WorkdayCalculator` falls back to a plain Monday–Friday week for them.
enum ChineseHolidaySchedule {
    enum DayKind: Equatable {
        /// A day off, whether or not it lands on a weekday.
        case holiday(StatutoryHoliday)
        /// A weekend the notice turns into a working day to bridge a holiday.
        case makeupWorkday(StatutoryHoliday)

        var holiday: StatutoryHoliday {
            switch self {
            case let .holiday(holiday), let .makeupWorkday(holiday):
                return holiday
            }
        }

        var name: String { holiday.title }
    }

    static func kind(of date: Date, calendar: Calendar) -> DayKind? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return nil
        }
        return table[CivilDateKey(year: year, month: month, day: day)]
    }

    static func coversYear(_ year: Int) -> Bool {
        coveredYears.contains(year)
    }

    // MARK: - Tables

    private struct HolidayRun {
        let holiday: StatutoryHoliday
        let start: (month: Int, day: Int)
        let end: (month: Int, day: Int)

        init(_ holiday: StatutoryHoliday, from start: (Int, Int), to end: (Int, Int)) {
            self.holiday = holiday
            self.start = (month: start.0, day: start.1)
            self.end = (month: end.0, day: end.1)
        }

        init(_ holiday: StatutoryHoliday, on day: (Int, Int)) {
            self.init(holiday, from: day, to: day)
        }
    }

    private struct MakeupRun {
        let holiday: StatutoryHoliday
        let month: Int
        let day: Int

        init(_ holiday: StatutoryHoliday, on day: (Int, Int)) {
            self.holiday = holiday
            self.month = day.0
            self.day = day.1
        }
    }

    private static let holidayRuns: [Int: [HolidayRun]] = [
        2025: [
            HolidayRun(.newYear, on: (1, 1)),
            HolidayRun(.springFestival, from: (1, 28), to: (2, 4)),
            HolidayRun(.qingming, from: (4, 4), to: (4, 6)),
            HolidayRun(.labourDay, from: (5, 1), to: (5, 5)),
            HolidayRun(.dragonBoat, from: (5, 31), to: (6, 2)),
            HolidayRun(.nationalDayAndMidAutumn, from: (10, 1), to: (10, 8)),
        ],
        2026: [
            HolidayRun(.newYear, from: (1, 1), to: (1, 3)),
            HolidayRun(.springFestival, from: (2, 15), to: (2, 23)),
            HolidayRun(.qingming, from: (4, 4), to: (4, 6)),
            HolidayRun(.labourDay, from: (5, 1), to: (5, 5)),
            HolidayRun(.dragonBoat, from: (6, 19), to: (6, 21)),
            HolidayRun(.midAutumn, from: (9, 25), to: (9, 27)),
            HolidayRun(.nationalDay, from: (10, 1), to: (10, 7)),
        ],
    ]

    private static let makeupRuns: [Int: [MakeupRun]] = [
        2025: [
            MakeupRun(.springFestival, on: (1, 26)),
            MakeupRun(.springFestival, on: (2, 8)),
            MakeupRun(.labourDay, on: (4, 27)),
            MakeupRun(.nationalDayAndMidAutumn, on: (9, 28)),
            MakeupRun(.nationalDayAndMidAutumn, on: (10, 11)),
        ],
        2026: [
            MakeupRun(.newYear, on: (1, 4)),
            MakeupRun(.springFestival, on: (2, 14)),
            MakeupRun(.springFestival, on: (2, 28)),
            MakeupRun(.labourDay, on: (5, 9)),
            MakeupRun(.nationalDay, on: (9, 20)),
            MakeupRun(.nationalDay, on: (10, 10)),
        ],
    ]

    private static let coveredYears: Set<Int> = Set(holidayRuns.keys)

    private static let table: [CivilDateKey: DayKind] = {
        var result: [CivilDateKey: DayKind] = [:]
        for (year, runs) in holidayRuns {
            for run in runs {
                let end = CivilDateKey(year: year, month: run.end.month, day: run.end.day)
                var cursor = CivilDateKey(year: year, month: run.start.month, day: run.start.day)
                while cursor <= end {
                    result[cursor] = .holiday(run.holiday)
                    guard let next = cursor.addingDays(1) else { break }
                    cursor = next
                }
            }
        }
        for (year, runs) in makeupRuns {
            for run in runs {
                let key = CivilDateKey(year: year, month: run.month, day: run.day)
                result[key] = .makeupWorkday(run.holiday)
            }
        }
        return result
    }()
}

/// How many workdays a month holds, and how far a date sits from today. Pure functions
/// over a caller-supplied `Calendar` — the month view and the settings pane have to
/// agree on the time zone and week start, so neither may reach for `.current`.
enum WorkdayCalculator {
    static func isWorkday(_ date: Date, scheme: WorkdayScheme, calendar: Calendar) -> Bool {
        if scheme == .chineseStatutory,
           let kind = ChineseHolidaySchedule.kind(of: date, calendar: calendar)
        {
            switch kind {
            case .holiday: return false
            case .makeupWorkday: return true
            }
        }
        // Gregorian weekdays are Sunday-based no matter where the week starts.
        let weekday = calendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }

    static func monthStats(
        month: Date,
        scheme: WorkdayScheme,
        calendar: Calendar,
        now: Date
    ) -> MonthWorkdayStats {
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let monthStart = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
        else {
            return MonthWorkdayStats(
                workdays: 0,
                restDays: 0,
                isEstimated: false,
                elapsedWorkdays: 0,
                containsToday: false
            )
        }

        let today = calendar.startOfDay(for: now)
        var workdays = 0
        var elapsed = 0
        for offset in 0..<dayRange.count {
            guard let date = calendar.date(byAdding: .day, value: offset, to: monthStart) else {
                continue
            }
            guard isWorkday(date, scheme: scheme, calendar: calendar) else { continue }
            workdays += 1
            // Today still counts as remaining, so only strictly earlier days are spent.
            if calendar.startOfDay(for: date) < today { elapsed += 1 }
        }

        let year = components.year ?? calendar.component(.year, from: monthStart)
        return MonthWorkdayStats(
            workdays: workdays,
            restDays: dayRange.count - workdays,
            isEstimated: scheme == .chineseStatutory && !ChineseHolidaySchedule.coversYear(year),
            elapsedWorkdays: elapsed,
            containsToday: calendar.isDate(now, equalTo: monthStart, toGranularity: .month)
        )
    }

    static func distance(from today: Date, to date: Date, calendar: Calendar) -> DateDistance {
        let start = calendar.startOfDay(for: today)
        let end = calendar.startOfDay(for: date)
        return DateDistance(days: calendar.dateComponents([.day], from: start, to: end).day ?? 0)
    }
}

struct MonthWorkdayStats: Equatable {
    let workdays: Int
    let restDays: Int
    /// The year has no published schedule, so these counts are plain Monday–Friday.
    let isEstimated: Bool
    /// Workdays strictly before today; only meaningful when `containsToday`.
    let elapsedWorkdays: Int
    let containsToday: Bool

    var remainingWorkdays: Int { workdays - elapsedWorkdays }

    var localizedSummary: String {
        let counts = L10n.format("%1$d workdays · %2$d days off", workdays, restDays)
        guard containsToday else { return counts }
        let progress = L10n.format("%1$d elapsed · %2$d left", elapsedWorkdays, remainingWorkdays)
        return "\(counts) · \(progress)"
    }
}

/// Whole days between two dates, signed: negative is in the past.
struct DateDistance: Equatable {
    let days: Int

    var magnitude: Int { abs(days) }
    var weeks: Int { magnitude / 7 }
    var remainderDays: Int { magnitude % 7 }
    /// Below a week the day count already reads clearly; from a week out the conversion
    /// is what makes the number graspable.
    var showsWeekBreakdown: Bool { magnitude >= 7 }

    var localizedDescription: String {
        switch days {
        case 0: return L10n.string("Today")
        case -1: return L10n.string("Yesterday")
        case 1: return L10n.string("Tomorrow")
        default: break
        }
        let plain = days < 0
            ? L10n.format("%d days ago", magnitude)
            : L10n.format("In %d days", magnitude)
        guard showsWeekBreakdown else { return plain }
        return L10n.format("%1$@ (%2$@)", plain, weekBreakdown)
    }

    private var weekBreakdown: String {
        switch (weeks, remainderDays) {
        case (1, 0): return L10n.format("%d week", weeks)
        case (_, 0): return L10n.format("%d weeks", weeks)
        case (1, 1): return L10n.format("%d week %d day", weeks, remainderDays)
        case (1, _): return L10n.format("%d week %d days", weeks, remainderDays)
        case (_, 1): return L10n.format("%d weeks %d day", weeks, remainderDays)
        default: return L10n.format("%d weeks %d days", weeks, remainderDays)
        }
    }
}
