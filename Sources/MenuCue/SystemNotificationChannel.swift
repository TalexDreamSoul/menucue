import Foundation
import UserNotifications

/// macOS-local delivery. It owns neither credentials nor network state: the first test or
/// actual alert asks the user for notification permission, then schedules the message on
/// this Mac through the system notification center.
protocol SystemNotificationScheduling: Sendable {
  func schedule(title: String, body: String, identifier: String) async throws
}

struct SystemNotificationChannel: NotificationChannel {
  let kind: NotificationChannelKind = .system
  private let scheduler: any SystemNotificationScheduling

  init(scheduler: any SystemNotificationScheduling = UserNotificationScheduler()) {
    self.scheduler = scheduler
  }

  func send(_ message: NotificationMessage) async throws -> NotificationReceipt {
    try message.validate()
    try await scheduler.schedule(
      title: message.title,
      body: message.body,
      identifier: "com.tagzxia.app.menucue.alert.\(message.eventID)"
    )
    return NotificationReceipt(kind: kind, eventID: message.eventID)
  }
}

private struct UserNotificationScheduler: SystemNotificationScheduling {
  func schedule(title: String, body: String, identifier: String) async throws {
    let center = UNUserNotificationCenter.current()
    let granted = try await center.requestAuthorization(options: [.alert, .sound])
    guard granted else { throw NotificationDeliveryError.permissionDenied }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }
}
