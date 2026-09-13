import Foundation
import XCTest

@testable import MenuCue

/// The alerts master switch promises that a paused outbox is not thrown away: alerts queued
/// while it was off are still in the store, and turning it back on is what flushes them.
final class NotificationDeliveryDispatcherTests: XCTestCase {
  func testMasterSwitchPausesTheOutboxAndTurningItBackOnFlushesIt() async throws {
    let store = try makeStore()
    try await store.commit(
      AlertRuntimeCommit(
        ruleID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        runtime: AlertRuleRuntime(),
        message: message(),
        channels: [.bark]
      ))

    let secrets = InMemoryNotificationSecretStore()
    try secrets.set(Data("bark-key".utf8), for: NotificationSecretField.barkDeviceKey)
    let recorder = DeliveryRecorder()
    let configuration = NotificationConfigurationService(
      secrets: secrets, transport: RecordingNotificationTransport(recorder: recorder))
    let dispatcher = NotificationDeliveryDispatcher(
      store: store,
      configuration: configuration,
      now: { Date(timeIntervalSince1970: 100) },
      sleep: { _ in try await Task.sleep(nanoseconds: .max) }
    )

    var enabled = NotificationSettings()
    enabled.updateChannel(.bark) { $0.isEnabled = true }
    var disabled = enabled
    disabled.isGloballyEnabled = false

    // Initial state is on, so switching it off is not a resume; the drain has to stay shut.
    await dispatcher.update(settings: disabled)
    await dispatcher.kick()

    let sendsWhilePaused = await recorder.count(afterMilliseconds: 50)
    XCTAssertEqual(sendsWhilePaused, 0, "off must not drain the outbox")
    var state = await deliveryState(in: store)
    XCTAssertEqual(state, .pending, "queued alerts have to survive a paused switch")

    await dispatcher.update(settings: enabled)

    let flushed = await recorder.waitForCount(1, timeoutMilliseconds: 2_000)
    XCTAssertTrue(
      flushed,
      "turning the switch back on has to flush what the pause held")
    state = await deliveryState(in: store, becoming: .delivered)
    XCTAssertEqual(state, .delivered, "the flushed alert is acknowledged as delivered")
  }

  private func makeStore() throws -> NotificationRuntimeStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MenuCue-\(UUID().uuidString)")
      .appendingPathComponent("notification-runtime-v1.json")
    return try NotificationRuntimeStore(fileURL: url)
  }

  private func message() -> NotificationMessage {
    NotificationMessage(
      eventID: "event-1",
      deviceName: "Studio Mac",
      ruleID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      state: .alert,
      occurredAt: Date(timeIntervalSince1970: 10),
      title: "High CPU",
      body: "CPU is 95%",
      metric: nil
    )
  }

  private func deliveryState(
    in store: NotificationRuntimeStore,
    becoming expected: NotificationRuntimeDeliveryState? = nil
  ) async -> NotificationRuntimeDeliveryState? {
    for _ in 0..<200 {
      let state = await store.snapshot().events.first?.deliveries[.bark]?.state
      if expected == nil || state == expected { return state }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await store.snapshot().events.first?.deliveries[.bark]?.state
  }
}

/// Counts the requests the dispatcher's channel actually made. The drain runs detached with
/// no completion signal, so the only way a test can tell "not yet" from "never" is to watch
/// this counter for a bounded window.
private actor DeliveryRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }

  func count(afterMilliseconds milliseconds: Int) async -> Int {
    for _ in 0..<milliseconds {
      if count > 0 { break }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return count
  }

  func waitForCount(_ expected: Int, timeoutMilliseconds: Int) async -> Bool {
    for _ in 0..<timeoutMilliseconds {
      if count >= expected { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return count >= expected
  }
}

private struct RecordingNotificationTransport: NotificationHTTPTransport {
  let recorder: DeliveryRecorder

  func data(for request: URLRequest) async throws -> NotificationHTTPResponse {
    await recorder.record()
    return NotificationHTTPResponse(
      statusCode: 200, headers: [:], data: Data(#"{"code":200}"#.utf8))
  }
}
