import CryptoKit
import Foundation

struct CivilDateKey: Hashable, Codable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: components.year ?? 1,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var isValid: Bool {
        guard let date = date(in: .gmt) else { return false }
        return CivilDateKey(date: date, timeZone: .gmt) == self
    }

    func date(in timeZone: TimeZone, hour: Int = 12) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))
    }

    func addingDays(_ value: Int) -> CivilDateKey? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = date(in: .gmt),
              let result = calendar.date(byAdding: .day, value: value, to: date)
        else {
            return nil
        }
        return CivilDateKey(date: result, timeZone: .gmt)
    }

    static func < (lhs: CivilDateKey, rhs: CivilDateKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

enum AllDayEventDatePolicy: String, CaseIterable, Codable, Identifiable {
    case preserveSource
    case overviewTimeZone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preserveSource:
            return L10n.string("Keep original all-day date")
        case .overviewTimeZone:
            return L10n.string("Use overview time zone")
        }
    }
}

enum TraditionalFestival: String, CaseIterable, Equatable {
    case springFestival
    case lanternFestival
    case longtaitou
    case dragonBoat
    case qixi
    case ghostFestival
    case midAutumn
    case doubleNinth
    case winterClothes
    case xiayuan
    case laba
    case newYearsEve

    var title: String {
        switch self {
        case .springFestival: return L10n.string("Spring Festival")
        case .lanternFestival: return L10n.string("Lantern Festival")
        case .longtaitou: return L10n.string("Longtaitou Festival")
        case .dragonBoat: return L10n.string("Dragon Boat Festival")
        case .qixi: return L10n.string("Qixi Festival")
        case .ghostFestival: return L10n.string("Ghost Festival")
        case .midAutumn: return L10n.string("Mid-Autumn Festival")
        case .doubleNinth: return L10n.string("Double Ninth Festival")
        case .winterClothes: return L10n.string("Winter Clothes Day")
        case .xiayuan: return L10n.string("Xiayuan Festival")
        case .laba: return L10n.string("Laba Festival")
        case .newYearsEve: return L10n.string("Lunar New Year's Eve")
        }
    }
}

struct LunarDateInfo: Equatable {
    let month: Int
    let day: Int
    let isLeapMonth: Bool
    let compactText: String
    let fullText: String
    let sexagenaryYearText: String
    let festival: TraditionalFestival?
}

final class LunarDateProvider {
    let timeZone: TimeZone
    let locale: Locale
    private let lunarCalendar: Calendar
    private let fullFormatter: DateFormatter
    private let sexagenaryFormatter: DateFormatter

    init(timeZone: TimeZone, locale: Locale) {
        self.timeZone = timeZone
        self.locale = locale

        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.timeZone = timeZone
        self.lunarCalendar = lunarCalendar

        let fullFormatter = DateFormatter()
        fullFormatter.calendar = lunarCalendar
        fullFormatter.timeZone = timeZone
        fullFormatter.locale = locale
        fullFormatter.dateStyle = .long
        fullFormatter.timeStyle = .none
        self.fullFormatter = fullFormatter

        let sexagenaryFormatter = DateFormatter()
        sexagenaryFormatter.calendar = lunarCalendar
        sexagenaryFormatter.timeZone = timeZone
        sexagenaryFormatter.locale = Locale(identifier: "zh-Hans")
        sexagenaryFormatter.dateFormat = "U"
        self.sexagenaryFormatter = sexagenaryFormatter
    }

    func info(for date: Date) -> LunarDateInfo? {
        let components = lunarCalendar.dateComponents(in: timeZone, from: date)
        guard let month = components.month, let day = components.day else { return nil }
        let isLeapMonth = components.isLeapMonth ?? false

        return LunarDateInfo(
            month: month,
            day: day,
            isLeapMonth: isLeapMonth,
            compactText: compactText(month: month, day: day, isLeapMonth: isLeapMonth),
            fullText: fullFormatter.string(from: date),
            sexagenaryYearText: sexagenaryFormatter.string(from: date),
            festival: TraditionalFestivalResolver.festival(
                for: date,
                lunarMonth: month,
                lunarDay: day,
                isLeapMonth: isLeapMonth,
                timeZone: timeZone
            )
        )
    }

    private func compactText(month: Int, day: Int, isLeapMonth: Bool) -> String {
        let isChinese = locale.identifier.lowercased().hasPrefix("zh")
        guard isChinese else {
            if day == 1 {
                return isLeapMonth ? "L*M\(month)" : "LM\(month)"
            }
            return "L\(day)"
        }

        if day == 1, Self.chineseMonths.indices.contains(month - 1) {
            return (isLeapMonth ? "闰" : "") + Self.chineseMonths[month - 1]
        }
        guard Self.chineseDays.indices.contains(day - 1) else { return String(day) }
        return Self.chineseDays[day - 1]
    }

    private static let chineseMonths = [
        "正月", "二月", "三月", "四月", "五月", "六月",
        "七月", "八月", "九月", "十月", "冬月", "腊月",
    ]

    private static let chineseDays = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
}

private enum TraditionalFestivalResolver {
    private static let fixedFestivals: [String: TraditionalFestival] = [
        "0101": .springFestival,
        "0115": .lanternFestival,
        "0202": .longtaitou,
        "0505": .dragonBoat,
        "0707": .qixi,
        "0715": .ghostFestival,
        "0815": .midAutumn,
        "0909": .doubleNinth,
        "1001": .winterClothes,
        "1015": .xiayuan,
        "1208": .laba,
    ]

    static func festival(
        for date: Date,
        lunarMonth: Int,
        lunarDay: Int,
        isLeapMonth: Bool,
        timeZone: TimeZone
    ) -> TraditionalFestival? {
        if !isLeapMonth {
            let key = String(format: "%02d%02d", lunarMonth, lunarDay)
            if let fixed = fixedFestivals[key] {
                return fixed
            }
        }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = timeZone
        guard lunarMonth == 12,
              let nextDate = gregorian.date(byAdding: .day, value: 1, to: date)
        else {
            return nil
        }
        let next = lunar.dateComponents(in: timeZone, from: nextDate)
        guard next.month == 1, next.day == 1, next.isLeapMonth != true else { return nil }
        return .newYearsEve
    }
}

enum SolarTerm: Int, CaseIterable, Equatable {
    case beginningOfSpring
    case rainWater
    case awakeningOfInsects
    case springEquinox
    case qingming
    case grainRain
    case beginningOfSummer
    case grainBuds
    case grainInEar
    case summerSolstice
    case minorHeat
    case majorHeat
    case beginningOfAutumn
    case endOfHeat
    case whiteDew
    case autumnEquinox
    case coldDew
    case frostDescent
    case beginningOfWinter
    case minorSnow
    case majorSnow
    case winterSolstice
    case minorCold
    case majorCold

    var title: String {
        switch self {
        case .beginningOfSpring: return L10n.string("Beginning of Spring")
        case .rainWater: return L10n.string("Rain Water")
        case .awakeningOfInsects: return L10n.string("Awakening of Insects")
        case .springEquinox: return L10n.string("Spring Equinox")
        case .qingming: return L10n.string("Qingming")
        case .grainRain: return L10n.string("Grain Rain")
        case .beginningOfSummer: return L10n.string("Beginning of Summer")
        case .grainBuds: return L10n.string("Grain Buds")
        case .grainInEar: return L10n.string("Grain in Ear")
        case .summerSolstice: return L10n.string("Summer Solstice")
        case .minorHeat: return L10n.string("Minor Heat")
        case .majorHeat: return L10n.string("Major Heat")
        case .beginningOfAutumn: return L10n.string("Beginning of Autumn")
        case .endOfHeat: return L10n.string("End of Heat")
        case .whiteDew: return L10n.string("White Dew")
        case .autumnEquinox: return L10n.string("Autumn Equinox")
        case .coldDew: return L10n.string("Cold Dew")
        case .frostDescent: return L10n.string("Frost Descent")
        case .beginningOfWinter: return L10n.string("Beginning of Winter")
        case .minorSnow: return L10n.string("Minor Snow")
        case .majorSnow: return L10n.string("Major Snow")
        case .winterSolstice: return L10n.string("Winter Solstice")
        case .minorCold: return L10n.string("Minor Cold")
        case .majorCold: return L10n.string("Major Cold")
        }
    }
}

enum SolarTermStoreError: Error {
    case invalidMetadata
    case checksumMismatch
    case invalidYearCoverage
    case invalidYear(Int)
    case invalidMonthDay(year: Int, value: String)
}

private struct SolarTermResourceMetadata: Decodable {
    let schemaVersion: Int
    let source: String
    let sourceRevision: String
    let sha256: String
}

struct SolarTermStore {
    static let referenceTimeZone = TimeZone(identifier: "Asia/Shanghai")!
    static let bundled: SolarTermStore? = {
        guard let dataURL = L10n.bundle.url(
            forResource: "solar-terms-1901-2100",
            withExtension: "json"
        ), let metadataURL = L10n.bundle.url(
            forResource: "solar-terms-1901-2100.metadata",
            withExtension: "json"
        ), let data = try? Data(contentsOf: dataURL),
           let metadataData = try? Data(contentsOf: metadataURL)
        else {
            return nil
        }
        return try? SolarTermStore(data: data, metadataData: metadataData)
    }()

    let coveredYears: ClosedRange<Int>
    let hasExactlyTwentyFourTermsPerYear: Bool
    let resourceSchemaVersion: Int
    let sourceRevision: String
    private let termsByDate: [CivilDateKey: SolarTerm]

    init(data: Data, metadataData: Data) throws {
        let metadata = try JSONDecoder().decode(
            SolarTermResourceMetadata.self,
            from: metadataData
        )
        guard metadata.schemaVersion == 1,
              !metadata.source.isEmpty,
              !metadata.sourceRevision.isEmpty
        else {
            throw SolarTermStoreError.invalidMetadata
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.sha256.lowercased() else {
            throw SolarTermStoreError.checksumMismatch
        }

        let decoded = try JSONDecoder().decode([String: [String]].self, from: data)
        let years = decoded.keys.compactMap(Int.init).sorted()
        guard years == Array(1901...2100) else { throw SolarTermStoreError.invalidYearCoverage }

        var terms: [CivilDateKey: SolarTerm] = [:]
        for year in years {
            guard let values = decoded[String(year)], values.count == SolarTerm.allCases.count else {
                throw SolarTermStoreError.invalidYear(year)
            }
            var seen = Set<CivilDateKey>()
            for (index, value) in values.enumerated() {
                guard value.count == 4,
                      let month = Int(value.prefix(2)),
                      let day = Int(value.suffix(2))
                else {
                    throw SolarTermStoreError.invalidMonthDay(year: year, value: value)
                }
                let key = CivilDateKey(year: year, month: month, day: day)
                guard key.isValid, seen.insert(key).inserted,
                      let term = SolarTerm(rawValue: index)
                else {
                    throw SolarTermStoreError.invalidMonthDay(year: year, value: value)
                }
                terms[key] = term
            }
        }

        self.coveredYears = 1901...2100
        self.hasExactlyTwentyFourTermsPerYear = true
        self.resourceSchemaVersion = metadata.schemaVersion
        self.sourceRevision = metadata.sourceRevision
        self.termsByDate = terms
    }

    func term(on date: CivilDateKey) -> SolarTerm? {
        termsByDate[date]
    }
}

struct CalendarDayPresentation: Identifiable, Equatable {
    let id: CivilDateKey
    let civilDate: CivilDateKey
    let date: Date
    let number: Int
    let weekNumber: Int
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let lunar: LunarDateInfo?
    let solarTerm: SolarTerm?
    let events: [CalendarEventInfo]

    var secondaryText: String? {
        lunar?.festival?.title ?? solarTerm?.title ?? lunar?.compactText
    }
}

struct CalendarMonthBuilder {
    let timeZone: TimeZone
    let weekStartDay: WeekStartDay
    let showsLunarCalendar: Bool
    let allDayEventDatePolicy: AllDayEventDatePolicy
    let solarTerms: SolarTermStore?

    func days(
        monthDate: Date,
        selectedDate: Date,
        now: Date,
        events: [CalendarEventInfo]
    ) -> [CalendarDayPresentation] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = weekStartDay.firstWeekday
        calendar.minimumDaysInFirstWeek = 1

        let visibleMonth = CivilDateKey(date: monthDate, timeZone: timeZone)
        let monthStart = CivilDateKey(year: visibleMonth.year, month: visibleMonth.month, day: 1)
        guard let monthStartDate = monthStart.date(in: timeZone) else { return [] }
        let weekday = calendar.component(.weekday, from: monthStartDate)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        guard let firstVisibleDate = monthStart.addingDays(-leadingDays) else { return [] }

        let selectedKey = CivilDateKey(date: selectedDate, timeZone: timeZone)
        let todayKey = CivilDateKey(date: now, timeZone: timeZone)
        let lunarProvider = LunarDateProvider(timeZone: timeZone, locale: L10n.appLocale)
        let eventsByDate = EventDateProjector.eventsByCivilDate(
            events,
            timeZone: timeZone,
            allDayPolicy: allDayEventDatePolicy
        )

        return (0..<42).compactMap { offset in
            guard let key = firstVisibleDate.addingDays(offset),
                  let date = key.date(in: timeZone)
            else {
                return nil
            }
            let lunar = showsLunarCalendar ? lunarProvider.info(for: date) : nil
            return CalendarDayPresentation(
                id: key,
                civilDate: key,
                date: date,
                number: key.day,
                weekNumber: calendar.component(.weekOfYear, from: date),
                isInMonth: key.year == visibleMonth.year && key.month == visibleMonth.month,
                isToday: key == todayKey,
                isSelected: key == selectedKey,
                lunar: lunar,
                solarTerm: showsLunarCalendar ? solarTerms?.term(on: key) : nil,
                events: eventsByDate[key] ?? []
            )
        }
    }
}
final class CalendarMonthPresentationCache {
    private struct Request: Equatable {
        let monthDate: CivilDateKey
        let selectedDate: CivilDateKey
        let currentDate: CivilDateKey
        let timeZoneIdentifier: String
        let timeZoneOffset: Int
        let weekStartDay: WeekStartDay
        let showsLunarCalendar: Bool
        let allDayEventDatePolicy: AllDayEventDatePolicy
        let events: [CalendarEventInfo]
    }

    private var cachedRequest: Request?
    private var cachedDays: [CalendarDayPresentation] = []

    func days(
        monthDate: Date,
        selectedDate: Date,
        now: Date,
        timeZone: TimeZone,
        weekStartDay: WeekStartDay,
        showsLunarCalendar: Bool,
        allDayEventDatePolicy: AllDayEventDatePolicy,
        events: [CalendarEventInfo],
        solarTerms: SolarTermStore?
    ) -> [CalendarDayPresentation] {
        let request = Request(
            monthDate: CivilDateKey(date: monthDate, timeZone: timeZone),
            selectedDate: CivilDateKey(date: selectedDate, timeZone: timeZone),
            currentDate: CivilDateKey(date: now, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            timeZoneOffset: timeZone.secondsFromGMT(for: monthDate),
            weekStartDay: weekStartDay,
            showsLunarCalendar: showsLunarCalendar,
            allDayEventDatePolicy: allDayEventDatePolicy,
            events: events
        )
        if cachedRequest == request {
            return cachedDays
        }

        let days = CalendarMonthBuilder(
            timeZone: timeZone,
            weekStartDay: weekStartDay,
            showsLunarCalendar: showsLunarCalendar,
            allDayEventDatePolicy: allDayEventDatePolicy,
            solarTerms: solarTerms
        ).days(
            monthDate: monthDate,
            selectedDate: selectedDate,
            now: now,
            events: events
        )
        cachedRequest = request
        cachedDays = days
        return days
    }
}


enum CalendarEventQueryPlanner {
    static func ranges(
        visibleMonthDate: Date,
        now: Date,
        timeZone: TimeZone,
        weekStartDay: WeekStartDay,
        daysAhead: Int
    ) -> [DateInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = weekStartDay.firstWeekday
        calendar.minimumDaysInFirstWeek = 1

        let monthKey = CivilDateKey(date: visibleMonthDate, timeZone: timeZone)
        let monthStartKey = CivilDateKey(year: monthKey.year, month: monthKey.month, day: 1)
        let monthStart = monthStartKey.date(in: timeZone, hour: 0) ?? visibleMonthDate
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let visibleStart = calendar.date(
            byAdding: .day,
            value: -(leadingDays + 2),
            to: monthStart
        ) ?? monthStart
        let visibleEnd = calendar.date(
            byAdding: .day,
            value: 44 - leadingDays,
            to: monthStart
        ) ?? monthStart.addingTimeInterval(Double(44 - leadingDays) * 86_400)

        let todayStart = calendar.startOfDay(for: now)
        let agendaStart = calendar.date(byAdding: .day, value: -2, to: todayStart) ?? todayStart
        let agendaEnd = calendar.date(byAdding: .day, value: daysAhead + 2, to: todayStart)
            ?? todayStart.addingTimeInterval(Double(daysAhead + 2) * 86_400)

        return [
            DateInterval(start: visibleStart, end: visibleEnd),
            DateInterval(start: agendaStart, end: agendaEnd),
        ]
    }
}

enum EventDateProjector {
    static func civilDates(
        for event: CalendarEventInfo,
        timeZone: TimeZone,
        allDayPolicy: AllDayEventDatePolicy
    ) -> [CivilDateKey] {
        if event.isAllDay, allDayPolicy == .preserveSource,
           let start = event.sourceStartCivilDate,
           let end = event.sourceEndCivilDateExclusive,
           start < end
        {
            return civilDates(from: start, toExclusive: end)
        }

        let start = CivilDateKey(date: event.startDate, timeZone: timeZone)
        guard event.endDate > event.startDate else { return [start] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = CivilDateKey(date: event.endDate, timeZone: timeZone)
        let endExclusive: CivilDateKey
        if event.endDate == calendar.startOfDay(for: event.endDate) {
            endExclusive = end
        } else {
            guard let next = end.addingDays(1) else { return [start] }
            endExclusive = next
        }
        return civilDates(from: start, toExclusive: endExclusive)
    }

    static func eventsByCivilDate(
        _ events: [CalendarEventInfo],
        timeZone: TimeZone,
        allDayPolicy: AllDayEventDatePolicy
    ) -> [CivilDateKey: [CalendarEventInfo]] {
        var result: [CivilDateKey: [CalendarEventInfo]] = [:]
        for event in events {
            for key in civilDates(for: event, timeZone: timeZone, allDayPolicy: allDayPolicy) {
                result[key, default: []].append(event)
            }
        }
        for key in result.keys {
            result[key]?.sort { $0.startDate < $1.startDate }
        }
        return result
    }

    private static func civilDates(
        from start: CivilDateKey,
        toExclusive end: CivilDateKey
    ) -> [CivilDateKey] {
        guard start < end else { return [start] }
        var dates: [CivilDateKey] = []
        var current = start
        while current < end, dates.count < 36_600 {
            dates.append(current)
            guard let next = current.addingDays(1) else { break }
            current = next
        }
        return dates
    }
}

enum AgendaEventProjector {
    static func eventsByCivilDate(
        _ events: [CalendarEventInfo],
        now: Date,
        days: Int = 7,
        timeZone: TimeZone,
        allDayPolicy: AllDayEventDatePolicy
    ) -> [CivilDateKey: [CalendarEventInfo]] {
        guard days > 0 else { return [:] }
        let today = CivilDateKey(date: now, timeZone: timeZone)
        guard let endExclusive = today.addingDays(days) else { return [:] }

        var result: [CivilDateKey: [CalendarEventInfo]] = [:]
        for event in events where event.isAllDay || event.endDate > now {
            for key in EventDateProjector.civilDates(
                for: event,
                timeZone: timeZone,
                allDayPolicy: allDayPolicy
            ) where key >= today && key < endExclusive {
                result[key, default: []].append(event)
            }
        }
        for key in result.keys {
            result[key]?.sort { $0.startDate < $1.startDate }
        }
        return result
    }
}
