import XCTest
@testable import MenuCue

final class PopoverTabNavigationTests: XCTestCase {
  func testMovingForwardCyclesThroughTabsAndWraps() {
    XCTAssertEqual(PopoverTab.status.moving(by: 1), .calendar)
    XCTAssertEqual(PopoverTab.calendar.moving(by: 1), .actions)
    XCTAssertEqual(PopoverTab.actions.moving(by: 1), .status)
  }

  func testMovingBackwardCyclesThroughTabsAndWraps() {
    XCTAssertEqual(PopoverTab.status.moving(by: -1), .actions)
    XCTAssertEqual(PopoverTab.actions.moving(by: -1), .calendar)
    XCTAssertEqual(PopoverTab.calendar.moving(by: -1), .status)
  }

  func testOnlyUserShortcutModifiersBlockArrowNavigation() {
    XCTAssertTrue(PopoverTab.allowsNavigation(modifiers: []))
    XCTAssertTrue(PopoverTab.allowsNavigation(modifiers: [.capsLock, .numericPad]))

    XCTAssertFalse(PopoverTab.allowsNavigation(modifiers: [.shift]))
    XCTAssertFalse(PopoverTab.allowsNavigation(modifiers: [.control]))
    XCTAssertFalse(PopoverTab.allowsNavigation(modifiers: [.option]))
    XCTAssertFalse(PopoverTab.allowsNavigation(modifiers: [.command]))
  }
}
