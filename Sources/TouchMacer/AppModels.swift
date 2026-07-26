import Foundation

enum MenuBarFormatMode: String, CaseIterable, Codable, Identifiable {
    case structured
    case advanced

    var id: String { rawValue }
    var title: String { self == .structured ? "Structured" : "Advanced" }
}

enum ClockCycle: String, CaseIterable, Codable, Identifiable {
    case system
    case twelveHour
    case twentyFourHour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }
}

enum MenuBarDateStyle: String, CaseIterable, Codable, Identifiable {
    case hidden
    case systemShort
    case abbreviated
    case iso

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .systemShort: return "System Short"
        case .abbreviated: return "Abbreviated"
        case .iso: return "ISO"
        }
    }
}

enum WeekdayStyle: String, CaseIterable, Codable, Identifiable {
    case hidden
    case short
    case full

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MenuBarSegmentOrder: String, CaseIterable, Codable, Identifiable {
    case dateThenTime
    case timeThenDate

    var id: String { rawValue }
    var title: String { self == .dateThenTime ? "Date, then time" : "Time, then date" }
}

struct MenuBarFormatSettings: Codable, Equatable {
    var mode: MenuBarFormatMode
    var clockCycle: ClockCycle
    var showsSeconds: Bool
    var dateStyle: MenuBarDateStyle
    var weekdayStyle: WeekdayStyle
    var segmentOrder: MenuBarSegmentOrder
    var advancedDatePattern: String
    var advancedTimePattern: String

    static let compatibilityDefault = MenuBarFormatSettings(
        mode: .structured,
        clockCycle: .twentyFourHour,
        showsSeconds: true,
        dateStyle: .abbreviated,
        weekdayStyle: .short,
        segmentOrder: .dateThenTime,
        advancedDatePattern: "EEE MMM d",
        advancedTimePattern: "HH:mm:ss"
    )
}

struct ClockEntry: Codable, Equatable, Identifiable {
    static let systemID = "system"

    let id: String
    let customLabel: String?

    var isSystem: Bool { id == Self.systemID }

    static func system(customLabel: String? = nil) -> ClockEntry {
        ClockEntry(id: systemID, customLabel: normalizedLabel(customLabel))
    }

    static func custom(identifier: String, customLabel: String? = nil) -> ClockEntry? {
        guard identifier != systemID, TimeZone(identifier: identifier) != nil else { return nil }
        return ClockEntry(id: identifier, customLabel: normalizedLabel(customLabel))
    }

    func updatingLabel(_ label: String?) -> ClockEntry {
        ClockEntry(id: id, customLabel: Self.normalizedLabel(label))
    }

    private static func normalizedLabel(_ label: String?) -> String? {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AppSettings: Equatable {
    var menuBarFormat: MenuBarFormatSettings
    private(set) var clockEntries: [ClockEntry]
    var statusBarSwitchIntervalSeconds: TimeInterval
    var appearanceMode: AppearanceMode
    var appearanceTimeZoneID: String
    var appliesSystemAppearance: Bool
    var overviewTimeZoneID: String
    var calendarWeekStartDay: WeekStartDay
    var calendarSelectionMode: CalendarSelectionMode
    var selectedCalendarIDs: Set<String>
    var pinnedQuickActions: [QuickActionReference]
    var preferenceSyncEnabled: Bool
    var preferenceSyncOnboardingCompleted: Bool
    var portableModificationDates: [PortableSettingField: Date]
    var iCloudIdentityTokenData: Data?
    var syncDeviceID: String

    init(
        menuBarFormat: MenuBarFormatSettings = .compatibilityDefault,
        clockEntries: [ClockEntry] = [.system()],
        statusBarSwitchIntervalSeconds: TimeInterval,
        appearanceMode: AppearanceMode,
        appearanceTimeZoneID: String,
        appliesSystemAppearance: Bool,
        overviewTimeZoneID: String,
        calendarWeekStartDay: WeekStartDay,
        calendarSelectionMode: CalendarSelectionMode,
        selectedCalendarIDs: Set<String>,
        pinnedQuickActions: [QuickActionReference],
        preferenceSyncEnabled: Bool = false,
        preferenceSyncOnboardingCompleted: Bool = false,
        portableModificationDates: [PortableSettingField: Date] = [:],
        iCloudIdentityTokenData: Data? = nil,
        syncDeviceID: String = UUID().uuidString
    ) {
        self.menuBarFormat = menuBarFormat
        self.clockEntries = Self.normalizedClockEntries(clockEntries)
        self.statusBarSwitchIntervalSeconds = statusBarSwitchIntervalSeconds
        self.appearanceMode = appearanceMode
        self.appearanceTimeZoneID = appearanceTimeZoneID
        self.appliesSystemAppearance = appliesSystemAppearance
        self.overviewTimeZoneID = overviewTimeZoneID
        self.calendarWeekStartDay = calendarWeekStartDay
        self.calendarSelectionMode = calendarSelectionMode
        self.selectedCalendarIDs = selectedCalendarIDs
        self.pinnedQuickActions = pinnedQuickActions
        self.preferenceSyncEnabled = preferenceSyncEnabled
        self.preferenceSyncOnboardingCompleted = preferenceSyncOnboardingCompleted
        self.portableModificationDates = portableModificationDates
        self.iCloudIdentityTokenData = iCloudIdentityTokenData
        self.syncDeviceID = syncDeviceID
    }

    var clockTimeZones: [ClockTimeZone] {
        clockEntries.compactMap { entry in
            if entry.isSystem {
                return .system(timeZone: .autoupdatingCurrent, customLabel: entry.customLabel)
            }
            return .custom(identifier: entry.id, customLabel: entry.customLabel)
        }
    }

    var displayTimeZone: TimeZone {
        clockTimeZones.first?.timeZone ?? .autoupdatingCurrent
    }

    var appearanceTimeZone: TimeZone {
        TimeZone(identifier: appearanceTimeZoneID) ?? displayTimeZone
    }

    var overviewTimeZone: TimeZone {
        TimeZone(identifier: overviewTimeZoneID) ?? displayTimeZone
    }

    func statusBarClock(at date: Date, switchInterval: TimeInterval? = nil) -> ClockTimeZone {
        let clocks = clockTimeZones
        let effectiveSwitchInterval = switchInterval ?? statusBarSwitchIntervalSeconds
        guard clocks.count > 1, effectiveSwitchInterval > 0 else { return clocks[0] }

        let slot = Int(floor(date.timeIntervalSinceReferenceDate / effectiveSwitchInterval))
        let index = ((slot % clocks.count) + clocks.count) % clocks.count
        return clocks[index]
    }

    @discardableResult
    mutating func addClock(identifier: String) -> Bool {
        guard !clockEntries.contains(where: { $0.id == identifier }) else { return false }
        guard let entry = ClockEntry.custom(identifier: identifier) else { return false }
        clockEntries.append(entry)
        return true
    }

    @discardableResult
    mutating func addSystemClock() -> Bool {
        guard !clockEntries.contains(where: \.isSystem) else { return false }
        clockEntries.append(.system())
        return true
    }

    @discardableResult
    mutating func removeClock(id: String) -> Bool {
        guard clockEntries.count > 1 else { return false }
        guard let index = clockEntries.firstIndex(where: { $0.id == id }) else { return false }
        clockEntries.remove(at: index)
        return true
    }

    @discardableResult
    mutating func moveClock(id: String, by offset: Int) -> Bool {
        guard let source = clockEntries.firstIndex(where: { $0.id == id }) else { return false }
        let destination = source + offset
        guard clockEntries.indices.contains(destination) else { return false }
        clockEntries.swapAt(source, destination)
        return true
    }

    mutating func moveClocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }
        let moving = source.sorted().map { clockEntries[$0] }
        var remaining = clockEntries.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = min(
            remaining.count,
            max(0, destination - removedBeforeDestination)
        )
        remaining.insert(contentsOf: moving, at: insertionIndex)
        clockEntries = remaining
    }

    @discardableResult
    mutating func updateClockLabel(id: String, label: String?) -> Bool {
        guard let index = clockEntries.firstIndex(where: { $0.id == id }) else { return false }
        let updated = clockEntries[index].updatingLabel(label)
        guard updated != clockEntries[index] else { return false }
        clockEntries[index] = updated
        return true
    }

    mutating func replaceClockEntries(_ entries: [ClockEntry]) {
        clockEntries = Self.normalizedClockEntries(entries)
    }

    private static func normalizedClockEntries(_ entries: [ClockEntry]) -> [ClockEntry] {
        var seen = Set<String>()
        var normalized: [ClockEntry] = []
        for entry in entries where seen.insert(entry.id).inserted {
            if entry.isSystem {
                normalized.append(.system(customLabel: entry.customLabel))
            } else if let custom = ClockEntry.custom(identifier: entry.id, customLabel: entry.customLabel) {
                normalized.append(custom)
            }
        }
        return normalized.isEmpty ? [.system()] : normalized
    }
}

struct ClockTimeZone: Identifiable, Equatable {
    let id: String
    let customLabel: String?
    let identifier: String
    let title: String
    let menuBarTitle: String
    let statusBarTitle: String
    let flag: String
    let subtitle: String
    let timeZone: TimeZone
    let isSystem: Bool

    static func system(timeZone: TimeZone, customLabel: String? = nil) -> ClockTimeZone {
        let title = customLabel ?? TimeZoneCatalog.shortTitle(for: timeZone.identifier)
        return ClockTimeZone(
            id: ClockEntry.systemID,
            customLabel: customLabel,
            identifier: timeZone.identifier,
            title: title,
            menuBarTitle: title,
            statusBarTitle: customLabel ?? TimeZoneCatalog.statusTitle(for: timeZone.identifier),
            flag: TimeZoneCatalog.flag(for: timeZone.identifier),
            subtitle: TimeZoneCatalog.displayName(for: timeZone.identifier),
            timeZone: timeZone,
            isSystem: true
        )
    }

    static func custom(identifier: String, customLabel: String? = nil) -> ClockTimeZone? {
        guard let timeZone = TimeZone(identifier: identifier) else { return nil }
        let title = customLabel ?? TimeZoneCatalog.shortTitle(for: identifier)
        return ClockTimeZone(
            id: identifier,
            customLabel: customLabel,
            identifier: identifier,
            title: title,
            menuBarTitle: title,
            statusBarTitle: customLabel ?? TimeZoneCatalog.statusTitle(for: identifier),
            flag: TimeZoneCatalog.flag(for: identifier),
            subtitle: TimeZoneCatalog.displayName(for: identifier),
            timeZone: timeZone,
            isSystem: false
        )
    }
}

enum ClockTransitionOrigin: Equatable {
    case top
    case bottom
}

struct ClockCarouselScrollIntent: Equatable {
    let carouselStep: Int
    let transitionOrigin: ClockTransitionOrigin

    init?(scrollingDeltaY: CGFloat, directionInvertedFromDevice: Bool) {
        guard scrollingDeltaY != 0 else { return nil }
        carouselStep = scrollingDeltaY > 0 ? -1 : 1

        let deviceDeltaY = directionInvertedFromDevice ? -scrollingDeltaY : scrollingDeltaY
        transitionOrigin = deviceDeltaY > 0 ? .bottom : .top
    }
}

enum ClockCarouselNavigator {
    static func adjacentClockID(
        in clocks: [ClockTimeZone],
        currentID: String?,
        step: Int
    ) -> String? {
        guard clocks.count > 1, step != 0 else { return nil }
        let currentIndex = currentID.flatMap { id in
            clocks.firstIndex(where: { $0.id == id })
        } ?? 0
        let normalizedStep = step > 0 ? 1 : -1
        let nextIndex = ((currentIndex + normalizedStep) % clocks.count + clocks.count)
            % clocks.count
        return clocks[nextIndex].id
    }
}

struct TemporaryClockSelection: Equatable {
    let clockID: String
    let expiresAt: Date

    init(clockID: String, selectedAt: Date, duration: TimeInterval) {
        self.clockID = clockID
        self.expiresAt = selectedAt.addingTimeInterval(duration)
    }

    func isActive(at date: Date) -> Bool {
        date < expiresAt
    }
}

struct StatusClockSelectionState: Equatable {
    var persistentClockID: String?
    var temporarySelection: TemporaryClockSelection?

    mutating func selectTemporarily(
        clockID: String,
        at date: Date,
        duration: TimeInterval
    ) {
        temporarySelection = TemporaryClockSelection(
            clockID: clockID,
            selectedAt: date,
            duration: duration
        )
    }

    mutating func selectPersistently(clockID: String) {
        persistentClockID = clockID
        temporarySelection = nil
    }

    mutating func resumeAutomaticRotation() {
        persistentClockID = nil
        temporarySelection = nil
    }

    mutating func removeUnavailableClockIDs(validClockIDs: Set<String>) {
        if let persistentClockID, !validClockIDs.contains(persistentClockID) {
            self.persistentClockID = nil
        }
        if let temporarySelection, !validClockIDs.contains(temporarySelection.clockID) {
            self.temporarySelection = nil
        }
    }
}

enum StatusClockResolver {
    static func clock(
        in settings: AppSettings,
        manualClockID: String?,
        temporarySelection: TemporaryClockSelection? = nil,
        at date: Date
    ) -> ClockTimeZone {
        let clocks = settings.clockTimeZones
        if let temporarySelection,
           let temporaryIndex = clocks.firstIndex(where: {
               $0.id == temporarySelection.clockID
           })
        {
            if temporarySelection.isActive(at: date) {
                return clocks[temporaryIndex]
            }
            if manualClockID == nil,
               clocks.count > 1,
               settings.statusBarSwitchIntervalSeconds > 0
            {
                let elapsed = max(0, date.timeIntervalSince(temporarySelection.expiresAt))
                let completedIntervals = Int(
                    floor(elapsed / settings.statusBarSwitchIntervalSeconds)
                )
                let index = (temporaryIndex + completedIntervals + 1) % clocks.count
                return clocks[index]
            }
        }
        if let manualClockID,
           let manualClock = clocks.first(where: { $0.id == manualClockID })
        {
            return manualClock
        }
        return settings.statusBarClock(at: date)
    }
}

enum TimeZoneMode: String, CaseIterable, Identifiable {
    case system
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .custom: return "Custom"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark
    case automaticByTimeZone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .automaticByTimeZone: return "Auto by Time Zone"
        }
    }
}

enum CalendarSelectionMode: String, CaseIterable, Identifiable {
    case all
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Calendars"
        case .custom: return "Selected Calendars"
        }
    }
}

enum WeekStartDay: Int, CaseIterable, Codable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }
    var firstWeekday: Int { rawValue }

    var title: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}


enum CalendarAuthorizationState: Equatable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted
    case unknown(String)

    var canReadEvents: Bool {
        self == .fullAccess
    }

    var title: String {
        switch self {
        case .notDetermined: return "Calendar access has not been requested."
        case .fullAccess: return "Calendar access granted."
        case .writeOnly: return "Calendar write-only access cannot read events."
        case .denied: return "Calendar access denied."
        case .restricted: return "Calendar access restricted."
        case .unknown(let value): return "Calendar access: \(value)."
        }
    }
}

struct CalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
}

struct CalendarEventInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let calendarTitle: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

struct QuickEventDraft: Equatable {
    var title: String
    var location: String
    var notes: String
    var urlString: String
    var calendarID: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var repeatMode: EventRepeatMode
    var alertMode: EventAlertMode

    init(startDate: Date, calendarID: String?) {
        let roundedStartDate = Self.roundedStartDate(from: startDate)
        self.title = "New Event"
        self.location = ""
        self.notes = ""
        self.urlString = ""
        self.calendarID = calendarID
        self.startDate = roundedStartDate
        self.endDate = roundedStartDate.addingTimeInterval(60 * 60)
        self.isAllDay = false
        self.repeatMode = .none
        self.alertMode = .none
    }

    private static func roundedStartDate(from date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let hourStart = calendar.date(from: components) else { return date }
        if date.timeIntervalSince(hourStart) == 0 {
            return hourStart
        }
        return calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? date
    }
}

enum EventRepeatMode: String, CaseIterable, Identifiable {
    case none
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

enum EventAlertMode: String, CaseIterable, Identifiable {
    case none
    case atStart
    case fiveMinutesBefore
    case fifteenMinutesBefore
    case oneHourBefore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .atStart: return "At start"
        case .fiveMinutesBefore: return "5 minutes before"
        case .fifteenMinutesBefore: return "15 minutes before"
        case .oneHourBefore: return "1 hour before"
        }
    }

    var relativeOffset: TimeInterval? {
        switch self {
        case .none: return nil
        case .atStart: return 0
        case .fiveMinutesBefore: return -5 * 60
        case .fifteenMinutesBefore: return -15 * 60
        case .oneHourBefore: return -60 * 60
        }
    }
}

enum TimeZoneCatalog {
    static let identifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted { left, right in
        displayName(for: left) < displayName(for: right)
    }

    static func displayName(for identifier: String) -> String {
        let timeZone = TimeZone(identifier: identifier) ?? .autoupdatingCurrent
        return "\(offsetText(for: timeZone))  \(shortTitle(for: identifier))"
    }

    static func shortTitle(for identifier: String) -> String {
        identifier.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? identifier
    }

    static func statusTitle(for identifier: String) -> String {
        let title = shortTitle(for: identifier)
        let knownCodes = [
            "Los Angeles": "LA",
            "New York": "NYC",
            "London": "LON",
            "Paris": "PAR",
            "Berlin": "BER",
            "Shanghai": "SHA",
            "Hong Kong": "HKG",
            "Singapore": "SG",
            "Tokyo": "TYO",
            "Seoul": "SEL",
            "Sydney": "SYD",
            "Dubai": "DXB"
        ]
        if let code = knownCodes[title] {
            return code
        }
        return title
            .split(separator: " ")
            .compactMap { $0.first }
            .prefix(3)
            .map { String($0).uppercased() }
            .joined()
    }

    static func flag(for identifier: String) -> String {
        guard let countryCode = countryCode(for: identifier) else { return "🌐" }
        return countryCode.uppercased().unicodeScalars.compactMap { scalar in
            UnicodeScalar(127397 + scalar.value).map(String.init)
        }.joined()
    }

    private static func countryCode(for identifier: String) -> String? {
        let normalizedIdentifier = identifier.replacingOccurrences(of: "_", with: " ")
        let city = shortTitle(for: identifier)
        let directMatches = [
            "America/Los Angeles": "US",
            "America/New York": "US",
            "America/Chicago": "US",
            "America/Denver": "US",
            "America/Phoenix": "US",
            "America/Anchorage": "US",
            "Pacific/Honolulu": "US",
            "America/Toronto": "CA",
            "America/Vancouver": "CA",
            "America/Mexico City": "MX",
            "America/Sao Paulo": "BR",
            "America/Buenos Aires": "AR",
            "Europe/London": "GB",
            "Europe/Paris": "FR",
            "Europe/Berlin": "DE",
            "Europe/Rome": "IT",
            "Europe/Madrid": "ES",
            "Europe/Amsterdam": "NL",
            "Europe/Zurich": "CH",
            "Europe/Stockholm": "SE",
            "Europe/Moscow": "RU",
            "Asia/Shanghai": "CN",
            "Asia/Hong Kong": "HK",
            "Asia/Singapore": "SG",
            "Asia/Tokyo": "JP",
            "Asia/Seoul": "KR",
            "Asia/Taipei": "TW",
            "Asia/Bangkok": "TH",
            "Asia/Jakarta": "ID",
            "Asia/Kolkata": "IN",
            "Asia/Dubai": "AE",
            "Asia/Jerusalem": "IL",
            "Australia/Sydney": "AU",
            "Australia/Melbourne": "AU",
            "Australia/Perth": "AU",
            "Pacific/Auckland": "NZ"
        ]
        if let countryCode = directMatches[normalizedIdentifier] {
            return countryCode
        }

        let cityMatches = [
            "Los Angeles": "US",
            "New York": "US",
            "London": "GB",
            "Paris": "FR",
            "Berlin": "DE",
            "Shanghai": "CN",
            "Hong Kong": "HK",
            "Singapore": "SG",
            "Tokyo": "JP",
            "Seoul": "KR",
            "Sydney": "AU",
            "Dubai": "AE"
        ]
        return cityMatches[city]
    }

    static func offsetText(for timeZone: TimeZone, date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}
