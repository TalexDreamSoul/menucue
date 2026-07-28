import EventKit
import Foundation

enum CalendarServiceError: LocalizedError {
    case missingDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .missingDefaultCalendar:
            return "No writable calendar is available for new events."
        }
    }
}

final class CalendarService {
    private let eventStore = EKEventStore()

    var authorizationState: CalendarAuthorizationState {
        Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess(completion: @escaping (CalendarAuthorizationState, Error?) -> Void) {
        eventStore.requestFullAccessToEvents { [weak self] _, error in
            guard let self else { return }
            completion(self.authorizationState, error)
        }
    }

    var defaultNewEventCalendarID: String? {
        eventStore.defaultCalendarForNewEvents?.calendarIdentifier
    }

    func calendars() -> [CalendarInfo] {
        eventStore.calendars(for: .event)
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

    func upcomingEvents(settings: AppSettings, daysAhead: Int = 14) -> [CalendarEventInfo] {
        let allCalendars = eventStore.calendars(for: .event)
        let selectedCalendars: [EKCalendar]
        switch settings.calendarSelectionMode {
        case .all:
            selectedCalendars = allCalendars
        case .custom:
            selectedCalendars = allCalendars.filter { settings.selectedCalendarIDs.contains($0.calendarIdentifier) }
        }

        guard !selectedCalendars.isEmpty else { return [] }

        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: startDate) ?? startDate.addingTimeInterval(14 * 24 * 60 * 60)
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: selectedCalendars)
        return eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { event in
                CalendarEventInfo(
                    id: event.eventIdentifier ?? "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.isEmpty == false ? event.title : "Untitled Event",
                    calendarTitle: event.calendar.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay
                )
            }
    }

    func createEvent(from draft: QuickEventDraft) throws {
        let event = EKEvent(eventStore: eventStore)
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.title = trimmedTitle.isEmpty ? "New Event" : trimmedTitle
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
