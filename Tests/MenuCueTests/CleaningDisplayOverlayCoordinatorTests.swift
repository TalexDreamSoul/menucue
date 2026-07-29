import AppKit
import XCTest
@testable import MenuCue

final class CleaningDisplayOverlayCoordinatorTests: XCTestCase {
  func testStartCreatesOneOverlayPerDisplay() {
    let displays = [
      CleaningDisplaySnapshot(id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900)),
      CleaningDisplaySnapshot(id: 2, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)),
    ]
    let harness = OverlayCoordinatorHarness(displays: displays)

    harness.coordinator.start()

    XCTAssertEqual(harness.created.map(\.displayID), [1, 2])
    XCTAssertEqual(harness.coordinator.overlayCount, 2)
  }

  func testDisplayChangeReconcilesRemovedRetainedAndAddedDisplays() {
    let harness = OverlayCoordinatorHarness(displays: [
      CleaningDisplaySnapshot(id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900)),
      CleaningDisplaySnapshot(id: 2, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)),
    ])
    harness.coordinator.start()
    let retainedOverlay = harness.created[1]

    harness.displays = [
      CleaningDisplaySnapshot(id: 2, frame: NSRect(x: 0, y: 0, width: 1728, height: 1117)),
      CleaningDisplaySnapshot(id: 3, frame: NSRect(x: -1280, y: 0, width: 1280, height: 720)),
    ]
    harness.notificationCenter.post(name: harness.changeNotification, object: nil)

    XCTAssertEqual(harness.created.map(\.displayID), [1, 2, 3])
    XCTAssertEqual(harness.removed.map(\.displayID), [1])
    XCTAssertTrue(
      harness.updated.contains { overlay, display in
        overlay === retainedOverlay && display.id == 2
          && display.frame == harness.displays[0].frame
      }
    )
    XCTAssertEqual(harness.coordinator.overlayCount, 2)
  }

  func testStopRemovesOverlaysAndDisplayObserver() {
    let harness = OverlayCoordinatorHarness(displays: [
      CleaningDisplaySnapshot(id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    ])
    harness.coordinator.start()

    harness.coordinator.stop()
    harness.displays = [
      CleaningDisplaySnapshot(id: 2, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
    ]
    harness.notificationCenter.post(name: harness.changeNotification, object: nil)

    XCTAssertEqual(harness.removed.map(\.displayID), [1])
    XCTAssertEqual(harness.created.map(\.displayID), [1])
    XCTAssertEqual(harness.coordinator.overlayCount, 0)
  }
}

private final class OverlayCoordinatorHarness {
  let notificationCenter = NotificationCenter()
  let changeNotification = Notification.Name("CleaningDisplayOverlayCoordinatorTests.change")
  var displays: [CleaningDisplaySnapshot]
  var created: [FakeCleaningOverlay] = []
  var updated: [(FakeCleaningOverlay, CleaningDisplaySnapshot)] = []
  var removed: [FakeCleaningOverlay] = []

  lazy var coordinator = CleaningDisplayOverlayCoordinator<FakeCleaningOverlay>(
    notificationCenter: notificationCenter,
    changeNotification: changeNotification,
    displays: { [unowned self] in displays },
    makeOverlay: { [unowned self] display in
      let overlay = FakeCleaningOverlay(displayID: display.id)
      created.append(overlay)
      return overlay
    },
    updateOverlay: { [unowned self] overlay, display in
      updated.append((overlay, display))
    },
    removeOverlay: { [unowned self] overlay in
      removed.append(overlay)
    }
  )

  init(displays: [CleaningDisplaySnapshot]) {
    self.displays = displays
  }
}

private final class FakeCleaningOverlay {
  let displayID: CGDirectDisplayID

  init(displayID: CGDirectDisplayID) {
    self.displayID = displayID
  }
}
