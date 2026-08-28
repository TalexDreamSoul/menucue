import Foundation
import XCTest

@testable import MenuCue

/// Stands in for the Quartz calls so a test can assert the property the user actually feels:
/// the calls are strictly paired, nothing freezes twice, and the sequence never ends frozen.
private final class RecordingPointerFreezer: PointerFreezing {
  enum Call: String {
    case freeze
    case unfreeze
  }

  private(set) var calls: [Call] = []

  var isPairedAndReleased: Bool {
    var depth = 0
    for call in calls {
      depth += call == .freeze ? 1 : -1
      guard (0...1).contains(depth) else { return false }
    }
    return depth == 0
  }

  func freeze() { calls.append(.freeze) }

  func unfreeze() { calls.append(.unfreeze) }
}

/// Drives the coordinator's two seams by hand: the clock never advances on its own and the
/// watchdog only fires when a test says so.
private final class PointerFreezeHarness {
  let freezer = RecordingPointerFreezer()
  var now: TimeInterval = 1_000
  private(set) var scheduledDelays: [TimeInterval] = []
  private var pendingWatchdog: (() -> Void)?

  private(set) lazy var coordinator = TrackpadPointerFreezeCoordinator(
    freezer: freezer,
    now: { [unowned self] in self.now },
    scheduleWatchdog: { [unowned self] delay, body in
      self.scheduledDelays.append(delay)
      self.pendingWatchdog = body
    }
  )

  var hasPendingWatchdog: Bool { pendingWatchdog != nil }

  func advance(by interval: TimeInterval) {
    now += interval
  }

  @discardableResult
  func fireWatchdog() -> Bool {
    guard let pendingWatchdog else { return false }
    self.pendingWatchdog = nil
    pendingWatchdog()
    return true
  }
}

/// The freeze itself is one call; the reason this has its own suite is the release. A path
/// that forgets to unfreeze leaves the user with a cursor that cannot move and no way to
/// reach the settings that would turn the feature off.
final class TrackpadPointerFreezeCoordinatorTests: XCTestCase {
  private let deviceID: UInt64 = 7

  func testAContinuousSessionFreezesOnceAndReleasesWhenTheContactsLift() {
    let harness = PointerFreezeHarness()

    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: true)
    XCTAssertEqual(harness.freezer.calls, [], "entering the corridor is not yet an adjustment")

    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: true)
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: true)
    XCTAssertEqual(
      harness.freezer.calls,
      [.freeze],
      "every later step of the same session rides the first freeze"
    )
    XCTAssertTrue(harness.coordinator.isFrozen)

    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: false)

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertFalse(harness.coordinator.isFrozen)
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  /// The engine and the recognizers are reset behind the service's back on a malformed
  /// frame, a removed device, sleep, and wake, and none of those produce a lift-off frame.
  func testAResetWhileTheFingersAreStillDownReleasesThePointer() {
    let harness = PointerFreezeHarness()
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)

    harness.coordinator.release()

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertFalse(harness.coordinator.isFrozen)

    // The abandoned session's own frames must not unfreeze a second time.
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: true)
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: false)

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  func testStoppingTheServiceReleasesThePointerAndReleasingAgainIsANoOp() {
    let harness = PointerFreezeHarness()
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)

    // `stop()` releases on the calling thread and again on the engine queue, and the
    // settings switch releases on top of both.
    harness.coordinator.release()
    harness.coordinator.release()
    harness.coordinator.release()

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  func testFramesThatStopArrivingReleaseThePointerOnTheWatchdogDeadline() {
    let harness = PointerFreezeHarness()
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
    XCTAssertEqual(harness.scheduledDelays, [TrackpadPointerFreezeCoordinator.stallTimeout])

    harness.advance(by: TrackpadPointerFreezeCoordinator.stallTimeout)
    XCTAssertTrue(harness.fireWatchdog())

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertFalse(harness.coordinator.isFrozen)
    XCTAssertFalse(harness.hasPendingWatchdog, "a released pointer needs no further watching")
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  func testTheWatchdogKeepsWaitingWhileFramesAreStillArriving() {
    let harness = PointerFreezeHarness()
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)

    // A slow adjustment can outlast the deadline while frames keep coming; only silence
    // counts as a stall.
    harness.advance(by: TrackpadPointerFreezeCoordinator.stallTimeout - 0.1)
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: true)
    harness.advance(by: 0.1)
    XCTAssertTrue(harness.fireWatchdog())

    XCTAssertEqual(harness.freezer.calls, [.freeze])
    XCTAssertTrue(harness.coordinator.isFrozen)
    XCTAssertTrue(harness.hasPendingWatchdog, "the watchdog has to re-arm or nothing is left")
    XCTAssertEqual(
      harness.scheduledDelays.last ?? 0,
      TrackpadPointerFreezeCoordinator.stallTimeout - 0.1,
      accuracy: 0.001,
      "re-arming for a full timeout would push the release out to twice the deadline"
    )

    harness.advance(by: TrackpadPointerFreezeCoordinator.stallTimeout)
    XCTAssertTrue(harness.fireWatchdog())

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  func testAWatchdogLeftOverFromAReleasedSessionDoesNothing() {
    let harness = PointerFreezeHarness()
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: false)

    harness.advance(by: TrackpadPointerFreezeCoordinator.stallTimeout)
    XCTAssertTrue(harness.fireWatchdog())

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  /// The scheduled block cannot be cancelled, so a session that starts before the previous
  /// session's watchdog has fired gets no watchdog of its own. If the inherited one did not
  /// re-arm against the new session's frames, a stall right here would freeze the pointer
  /// for good.
  func testASessionStartedUnderALeftoverWatchdogIsStillReleasedOnItsOwnDeadline() {
    let harness = PointerFreezeHarness()
    let timeout = TrackpadPointerFreezeCoordinator.stallTimeout
    // How long after the first session ends the second one starts, and therefore how far
    // the second session's deadline trails the leftover watchdog's.
    let gap: TimeInterval = 0.5
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
    harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: false)

    harness.advance(by: gap)
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
    XCTAssertEqual(
      harness.scheduledDelays,
      [timeout],
      "the second session rides the watchdog the first one left behind"
    )

    // The leftover fires on the first session's deadline, which the second session will not
    // reach for another `gap`, so it hands itself exactly that much.
    harness.advance(by: timeout - gap)
    XCTAssertTrue(harness.fireWatchdog())
    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze, .freeze])
    XCTAssertEqual(harness.scheduledDelays.last ?? 0, gap, accuracy: 0.001)

    harness.advance(by: gap)
    XCTAssertTrue(harness.fireWatchdog())

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze, .freeze, .unfreeze])
    XCTAssertFalse(harness.coordinator.isFrozen)
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  /// A second trackpad's frames carry their own contacts and say nothing about the hand
  /// holding the adjustment.
  func testAnotherDeviceNeitherReleasesNorRefreshesTheOwningSession() {
    let harness = PointerFreezeHarness()
    let otherDeviceID: UInt64 = 9
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)

    harness.advance(by: TrackpadPointerFreezeCoordinator.stallTimeout - 0.1)
    harness.coordinator.observeFrame(deviceID: otherDeviceID, hasContacts: false)
    XCTAssertTrue(harness.coordinator.isFrozen)

    harness.coordinator.observeFrame(deviceID: otherDeviceID, hasContacts: true)
    harness.advance(by: 0.2)
    XCTAssertTrue(harness.fireWatchdog())

    XCTAssertEqual(
      harness.freezer.calls,
      [.freeze, .unfreeze],
      "another device's frames must not stand in for the owner's"
    )
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  /// The second trackpad may still take the adjustment over, and the pointer is one pointer.
  func testASecondDeviceTakingOverDoesNotFreezeTwice() {
    let harness = PointerFreezeHarness()
    let otherDeviceID: UInt64 = 9
    harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)

    harness.coordinator.beginContinuousAdjustment(deviceID: otherDeviceID)
    XCTAssertEqual(harness.freezer.calls, [.freeze])

    harness.coordinator.observeFrame(deviceID: otherDeviceID, hasContacts: false)

    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  /// The other tests drive the coordinator by hand. This one drives it the way the service
  /// does — from what the engine actually recognized — so the newest family declaring
  /// `freezesPointer` is proved to reach the freeze and, more importantly, the release.
  func testAnAnchoredSlideSessionFreezesOnItsFirstStepAndReleasesOnLiftOff() {
    let harness = PointerFreezeHarness()
    let engine = TrackpadGestureEngine(
      settings: TrackpadGestureSettings(
        isEnabled: true,
        rules: [
          TrackpadGestureRule(
            name: "Anchored slide",
            trigger: TrackpadGestureTrigger(
              kind: .anchoredSlide,
              fingerCount: 2,
              selectedFingerIndex: 0,
              slideAxis: .vertical,
              movementTolerance: 0.03,
              minimumDistance: 0.05
            ),
            action: .system(.continuousVolume)
          )
        ]
      )
    )
    let slide: [(timestamp: TimeInterval, state: TrackpadContactState, y: Double)] = [
      (0, .touch, 0.50),
      (0.10, .touch, 0.59),
      (0.20, .touch, 0.68),
      (0.30, .out, 0.68),
    ]

    var steps = 0
    for (index, step) in slide.enumerated() {
      let contacts = [
        TrackpadContact(id: 1, state: step.state, position: TrackpadPoint(x: 0.30, y: step.y)),
        TrackpadContact(
          id: 2,
          state: step.state,
          position: TrackpadPoint(x: 0.70, y: 0.50)
        ),
      ]
      let matches = engine.consume(
        frame: TrackpadFrame(
          deviceID: deviceID,
          isBuiltIn: true,
          timestamp: step.timestamp,
          frameNumber: Int32(index + 1),
          contacts: contacts
        ),
        context: TrackpadGestureContext(bundleIdentifier: "com.example.editor")
      )
      steps += matches.count
      if matches.contains(where: \.freezesPointer) {
        harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
      }
      harness.coordinator.observeFrame(
        deviceID: deviceID,
        hasContacts: contacts.contains { $0.state.isTouching }
      )
    }

    XCTAssertEqual(steps, 2, "the session has to have adjusted something to be worth freezing")
    XCTAssertEqual(harness.freezer.calls, [.freeze, .unfreeze])
    XCTAssertFalse(harness.coordinator.isFrozen)
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }

  func testEverySessionAfterAReleaseFreezesAgain() {
    let harness = PointerFreezeHarness()

    for _ in 0..<3 {
      harness.coordinator.beginContinuousAdjustment(deviceID: deviceID)
      harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: true)
      harness.coordinator.observeFrame(deviceID: deviceID, hasContacts: false)
    }

    XCTAssertEqual(
      harness.freezer.calls,
      [.freeze, .unfreeze, .freeze, .unfreeze, .freeze, .unfreeze]
    )
    XCTAssertTrue(harness.freezer.isPairedAndReleased)
  }
}
