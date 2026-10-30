import Foundation

/// A local-time reminder cadence. The scheduler keeps delivery state separately so changing
/// the copy or channel list does not make an already-fired reminder fire twice.
enum ReminderSchedule: Codable, Equatable, Sendable {
  case daily(hour: Int, minute: Int)
  case everyDays(days: Int)
  case everyHours(hours: Int, startHour: Int, endHour: Int)
}

struct ReminderRule: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var isEnabled: Bool
  var schedule: ReminderSchedule
  var title: String
  var body: String
  var channels: Set<NotificationChannelKind>
  /// When set, a closed lid can trigger this rule once per local day after the given hour.
  var lidCloseAfterHour: Int?

  init(
    id: UUID = UUID(),
    name: String,
    isEnabled: Bool = true,
    schedule: ReminderSchedule,
    title: String,
    body: String,
    channels: Set<NotificationChannelKind> = [.system],
    lidCloseAfterHour: Int? = nil
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.isEnabled = isEnabled
    self.schedule = schedule
    self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    self.channels = channels
    self.lidCloseAfterHour = lidCloseAfterHour.map { min(23, max(0, $0)) }
  }
}

enum DefaultReminderRuleID {
  static let screenCleaning = UUID(uuidString: "B2F5C7E4-40D9-4B1C-9E24-9D0D4C1A77F1")!
  static let water = UUID(uuidString: "D1E2A3B4-C5D6-47E8-9F10-112131415161")!
  static let meal = UUID(uuidString: "E4F5A6B7-C8D9-40EA-BF12-223242526272")!
  static let offWork = UUID(uuidString: "F6A7B8C9-D0E1-42F3-A415-334353637383")!
  static let clockOut = UUID(uuidString: "A7B8C9D0-E1F2-43A4-B526-445565758595")!
}

enum DefaultReminderRules {
  static func all() -> [ReminderRule] {
    [
      ReminderRule(
        id: DefaultReminderRuleID.screenCleaning,
        name: L10n.string("Clean the screen"),
        schedule: .everyDays(days: 7),
        title: L10n.string("Time to clean the screen"),
        body: L10n.string("A clean screen makes every gesture easier to see.")),
      ReminderRule(
        id: DefaultReminderRuleID.water,
        name: L10n.string("Drink water"),
        schedule: .everyHours(hours: 2, startHour: 9, endHour: 18),
        title: L10n.string("Drink some water"),
        body: L10n.string("Take a short break and drink some water.")),
      ReminderRule(
        id: DefaultReminderRuleID.meal,
        name: L10n.string("Order lunch"),
        schedule: .daily(hour: 11, minute: 0),
        title: L10n.string("Order lunch"),
        body: L10n.string("It is around lunch time.")),
      ReminderRule(
        id: DefaultReminderRuleID.offWork,
        name: L10n.string("Finish work"),
        schedule: .daily(hour: 17, minute: 0),
        title: L10n.string("Time to finish work"),
        body: L10n.string("Remember to wrap up and finish work.")),
      ReminderRule(
        id: DefaultReminderRuleID.clockOut,
        name: L10n.string("Clock out"),
        schedule: .daily(hour: 17, minute: 30),
        title: L10n.string("Remember to clock out"),
        body: L10n.string("Remember to clock out before leaving.") ,
        channels: [.system, .bark],
        lidCloseAfterHour: 17),
    ]
  }
}

extension ReminderSchedule {
  var summary: String {
    switch self {
    case let .daily(hour, minute):
      return L10n.format("Daily at %@", Self.clockText(hour: hour, minute: minute))
    case let .everyDays(days):
      return L10n.format("Every %d days", days)
    case let .everyHours(hours, startHour, endHour):
      return L10n.format(
        "Every %d hours from %@ to %@",
        hours,
        Self.clockText(hour: startHour, minute: 0),
        Self.clockText(hour: endHour, minute: 0))
    }
  }

  private static func clockText(hour: Int, minute: Int) -> String {
    String(format: "%02d:%02d", min(23, max(0, hour)), min(59, max(0, minute)))
  }
}
