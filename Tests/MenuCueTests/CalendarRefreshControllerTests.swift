import AppKit
import XCTest
@testable import MenuCue

final class CalendarRefreshControllerTests: XCTestCase {
    func testObservedSystemAndWakeNotificationsCoalesceIntoOneRefresh() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let refreshed = expectation(description: "calendar refreshed")
        var refreshCount = 0
        let controller = CalendarRefreshController(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            delay: 0.02
        ) {
            refreshCount += 1
            refreshed.fulfill()
        }

        for name in CalendarRefreshController.observedNames {
            notificationCenter.post(name: name, object: nil)
        }
        workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(refreshCount, 1)
        withExtendedLifetime(controller) {}
    }
}
