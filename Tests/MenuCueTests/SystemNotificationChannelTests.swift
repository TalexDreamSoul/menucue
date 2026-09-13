import Foundation
import XCTest

@testable import MenuCue

/// The native channel never touches `UNUserNotificationCenter` directly in tests: it
/// schedules through the injected seam, which is exactly the boundary these tests hold it
/// to — validate first, forward the message intact, keep the alert identifier stable, and
/// surface a denied permission instead of pretending delivery happened.
final class SystemNotificationChannelTests: XCTestCase {
  func testSchedulesThroughTheInjectedSchedulerUnderTheStableAlertIdentifier() async throws {
    let scheduler = RecordingSystemNotificationScheduler()
    let channel = SystemNotificationChannel(scheduler: scheduler)

    let receipt = try await channel.send(message())

    XCTAssertEqual(receipt.kind, .system)
    XCTAssertEqual(receipt.eventID, "event-1")
    let scheduled = await scheduler.recorded()
    XCTAssertEqual(scheduled.count, 1, "one alert is one notification")
    XCTAssertEqual(scheduled.first?.title, "High CPU")
    XCTAssertEqual(scheduled.first?.body, "CPU stayed above 90% for 5 minutes.")
    XCTAssertEqual(
      scheduled.first?.identifier, "com.tagzxia.app.menucue.alert.event-1",
      "the identifier must stay namespaced and per-event so replacements beside it survive"
    )
  }

  func testRejectsAnInvalidMessageWithoutSchedulingAnything() async {
    let scheduler = RecordingSystemNotificationScheduler()
    let channel = SystemNotificationChannel(scheduler: scheduler)
    let invalid = NotificationMessage(
      eventID: "event-1", deviceName: "Mac", ruleID: "rule-1", state: .alert,
      occurredAt: Date(), title: "   ", body: "Body", metric: nil)

    do {
      _ = try await channel.send(invalid)
      XCTFail("a whitespace-only title must be rejected before it reaches the notification center")
    } catch let error as NotificationDeliveryError {
      XCTAssertEqual(error, .invalidConfiguration)
    } catch {
      XCTFail("unexpected error \(error)")
    }
    let scheduled = await scheduler.recorded()
    XCTAssertTrue(scheduled.isEmpty, "a rejected message must not be scheduled")
  }

  func testDeniedSystemPermissionPropagatesAsPermissionDenied() async {
    let scheduler = RecordingSystemNotificationScheduler(error: .permissionDenied)
    let channel = SystemNotificationChannel(scheduler: scheduler)

    do {
      _ = try await channel.send(message())
      XCTFail("a denied permission means nothing was delivered")
    } catch let error as NotificationDeliveryError {
      XCTAssertEqual(error, .permissionDenied)
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  private func message() -> NotificationMessage {
    NotificationMessage(
      eventID: "event-1", deviceName: "Mac", ruleID: "rule-1", state: .alert,
      occurredAt: Date(), title: "High CPU", body: "CPU stayed above 90% for 5 minutes.",
      metric: NotificationMetricContext(
        id: "cpu.total.busy", value: 0.96, unit: "ratio", threshold: 0.9))
  }
}

private actor RecordingSystemNotificationScheduler: SystemNotificationScheduling {
  struct Scheduled: Equatable, Sendable {
    let title: String
    let body: String
    let identifier: String
  }

  private let error: NotificationDeliveryError?
  private var scheduledMessages: [Scheduled] = []

  init(error: NotificationDeliveryError? = nil) {
    self.error = error
  }

  func schedule(title: String, body: String, identifier: String) async throws {
    if let error { throw error }
    scheduledMessages.append(Scheduled(title: title, body: body, identifier: identifier))
  }

  func recorded() -> [Scheduled] { scheduledMessages }
}
