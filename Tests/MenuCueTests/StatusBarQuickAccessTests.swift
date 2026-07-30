import AppKit
import XCTest

@testable import MenuCue

@MainActor
final class StatusBarQuickAccessTests: XCTestCase {
  func testUpdateMenuItemUsesUpdateActionAndAvailability() {
    let target = QuickAccessMenuTarget()
    let action = #selector(QuickAccessMenuTarget.checkForUpdates(_:))

    let enabledItem = StatusContextMenuItemFactory.checkForUpdatesItem(
      target: target,
      action: action,
      isEnabled: true
    )
    let disabledItem = StatusContextMenuItemFactory.checkForUpdatesItem(
      target: target,
      action: action,
      isEnabled: false
    )

    XCTAssertEqual(enabledItem.title, L10n.string("Check for Updates"))
    XCTAssertTrue(enabledItem.target === target)
    XCTAssertEqual(enabledItem.action, action)
    XCTAssertTrue(enabledItem.isEnabled)
    XCTAssertFalse(disabledItem.isEnabled)
  }

  func testSettingsWindowDockLifecycleUsesRegularThenAccessoryPolicies() {
    var policies: [NSApplication.ActivationPolicy] = []
    let controller = SettingsWindowDockController { policy in
      policies.append(policy)
      return true
    }

    controller.settingsWillShow()
    controller.settingsDidClose()

    XCTAssertEqual(policies, [.regular, .accessory])
  }
}

@MainActor
private final class QuickAccessMenuTarget: NSObject {
  @objc func checkForUpdates(_ sender: NSMenuItem) {}
}
