import EventKit
import Foundation

enum CalendarEventOccurrenceIdentifier {
    static func make(
        eventIdentifier: String?,
        calendarItemIdentifier: String,
        startDate: Date
    ) -> String {
        let base = eventIdentifier ?? calendarItemIdentifier
        return "\(base)-\(startDate.timeIntervalSinceReferenceDate.bitPattern)"
    }
}

enum CalendarServiceError: LocalizedError {
    case missingDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .missingDefaultCalendar:
            return L10n.string("No writable calendar is available for new events.")
        }
    }
}

final class CalendarService {
    private let eventStore = EKEventStore()
    private let eventStoreQueue = DispatchQueue(
        label: "com.tagzxia.app.menucue.calendar-event-store",
        qos: .userInitiated
    )

    var authorizationState: CalendarAuthorizationState {
        Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess(completion: @escaping (CalendarAuthorizationState, Error?) -> Void) {
        eventStoreQueue.async { [weak self] in
            guard let self else { return }
            let finish: (Bool, Error?) -> Void = { [weak self] _, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    completion(self.authorizationState, error)
                }
            }
            if #available(macOS 14.0, *) {
                self.eventStore.requestFullAccessToEvents(completion: finish)
            } else {
                self.eventStore.requestAccess(to: .event, completion: finish)
            }
        }
    }

    func load(
        settings: AppSettings,
        visibleMonthDate: Date,
        completion: @escaping ([CalendarInfo], [CalendarEventInfo]) -> Void
    ) {
        eventStoreQueue.async { [weak self] in
            guard let self else { return }
            let allCalendars = self.eventStore.calendars(for: .event)
            let calendars = self.calendarInfos(from: allCalendars)
            let events = self.eventInfos(
                settings: settings,
                visibleMonthDate: visibleMonthDate,
                allCalendars: allCalendars
            )
            DispatchQueue.main.async {
                completion(calendars, events)
            }
        }
    }

    func loadEvents(
        settings: AppSettings,
        visibleMonthDate: Date,
        completion: @escaping ([CalendarEventInfo]) -> Void
    ) {
        eventStoreQueue.async { [weak self] in
            guard let self else { return }
            let events = self.eventInfos(
                settings: settings,
                visibleMonthDate: visibleMonthDate,
                allCalendars: self.eventStore.calendars(for: .event)
            )
            DispatchQueue.main.async {
                completion(events)
            }
        }
    }

    var defaultNewEventCalendarID: String? {
        eventStoreQueue.sync {
            eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        }
    }

    func createEvent(from draft: QuickEventDraft) throws {
        try eventStoreQueue.sync {
            try saveEvent(from: draft)
        }
    }

    private func calendarInfos(from calendars: [EKCalendar]) -> [CalendarInfo] {
        calendars
            .sorted { left, right in
                if left.source.title == right.source.title {
                    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
                }
                return left.source.title.localizedCaseInsensitiveCompare(right.source.title) == .orderedAscending
            }
            .map { calendar in
                CalendarInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title
                )
            }
    }

    private func eventInfos(
        settings: AppSettings,
        visibleMonthDate: Date,
        allCalendars: [EKCalendar]
    ) -> [CalendarEventInfo] {
        let selectedCalendars: [EKCalendar]
        switch settings.calendarSelectionMode {
        case .all:
            selectedCalendars = allCalendars
        case .custom:
            selectedCalendars = allCalendars.filter {
                settings.selectedCalendarIDs.contains($0.calendarIdentifier)
            }
        }

        guard !selectedCalendars.isEmpty else { return [] }

        let ranges = CalendarEventQueryPlanner.ranges(
            visibleMonthDate: visibleMonthDate,
            now: Date(),
            timeZone: settings.overviewTimeZone,
            weekStartDay: settings.calendarWeekStartDay,
            daysAhead: 14
        )
        var eventsByID: [String: EKEvent] = [:]
        for range in ranges {
            let predicate = eventStore.predicateForEvents(
                withStart: range.start,
                end: range.end,
                calendars: selectedCalendars
            )
            for event in eventStore.events(matching: predicate) {
                let occurrenceID = CalendarEventOccurrenceIdentifier.make(
                    eventIdentifier: event.eventIdentifier,
                    calendarItemIdentifier: event.calendarItemIdentifier,
                    startDate: event.startDate
                )
                eventsByID[occurrenceID] = event
            }
        }

        let sourceTimeZone = TimeZone.autoupdatingCurrent
        return eventsByID.values
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEventInfo(
                    id: CalendarEventOccurrenceIdentifier.make(
                        eventIdentifier: event.eventIdentifier,
                        calendarItemIdentifier: event.calendarItemIdentifier,
                        startDate: event.startDate
                    ),
                    title: event.title?.isEmpty == false
                        ? event.title : L10n.string("Untitled Event"),
                    calendarTitle: event.calendar.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    sourceStartCivilDate: event.isAllDay
                        ? CivilDateKey(date: event.startDate, timeZone: sourceTimeZone) : nil,
                    sourceEndCivilDateExclusive: event.isAllDay
                        ? CivilDateKey(date: event.endDate, timeZone: sourceTimeZone) : nil
                )
            }
    }

    private func saveEvent(from draft: QuickEventDraft) throws {
        let event = EKEvent(eventStore: eventStore)
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.title = trimmedTitle.isEmpty ? L10n.string("New Event") : trimmedTitle
        event.location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        event.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        event.url = URL(string: draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines))
        event.isAllDay = draft.isAllDay
        event.startDate = draft.startDate
        event.endDate = max(draft.endDate, draft.startDate.addingTimeInterval(60))
        guard let targetCalendar = calendar(for: draft.calendarID) ?? eventStore.defaultCalendarForNewEvents else {
            throw CalendarServiceError.missingDefaultCalendar
        }
        event.calendar = targetCalendar
        if let relativeOffset = draft.alertMode.relativeOffset {
            event.addAlarm(EKAlarm(relativeOffset: relativeOffset))
        }
        if let frequency = draft.repeatMode.eventKitFrequency {
            event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil))
        }
        try eventStore.save(event, span: .thisEvent)
    }

    private func calendar(for identifier: String?) -> EKCalendar? {
        guard let identifier else { return nil }
        return eventStore.calendars(for: .event).first { $0.calendarIdentifier == identifier }
    }

    private static func mapAuthorizationStatus(_ status: EKAuthorizationStatus) -> CalendarAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .fullAccess
        case .fullAccess:
            return .fullAccess
        case .writeOnly:
            return .writeOnly
        @unknown default:
            return .unknown(String(describing: status))
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension EventRepeatMode {
    var eventKitFrequency: EKRecurrenceFrequency? {
        switch self {
        case .none: return nil
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }
}
