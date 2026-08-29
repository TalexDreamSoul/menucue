import CoreGraphics
import XCTest

@testable import MenuCue

/// Moving a window to the next display is arithmetic on rectangles, and the rectangles that
/// break it — a portrait display, a smaller one, a single one — are exactly the ones the
/// machine running these tests does not have.
final class WindowDisplayGeometryTests: XCTestCase {
  /// Two displays side by side, the right one smaller, in AppKit coordinates.
  private let left = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  private let right = CGRect(x: 1600, y: 0, width: 800, height: 600)

  func testTheNextDisplayWrapsPastTheLastOne() {
    XCTAssertEqual(WindowDisplayGeometry.nextIndex(after: 0, count: 3), 1)
    XCTAssertEqual(WindowDisplayGeometry.nextIndex(after: 1, count: 3), 2)
    XCTAssertEqual(
      WindowDisplayGeometry.nextIndex(after: 2, count: 3), 0,
      "the last display's neighbour is the first one, or the action is a dead end there")
  }

  func testASingleDisplayHasNoNextDisplay() {
    XCTAssertNil(
      WindowDisplayGeometry.nextIndex(after: 0, count: 1),
      "nowhere to move to is what the action reports as unavailable")
    XCTAssertNil(WindowDisplayGeometry.nextIndex(after: 0, count: 0))
    XCTAssertNil(WindowDisplayGeometry.nextIndex(after: 4, count: 2))
  }

  func testAWindowBelongsToWhicheverDisplayShowsMoreOfIt() {
    let mostlyLeft = CGRect(x: 1300, y: 100, width: 400, height: 300)
    let mostlyRight = CGRect(x: 1500, y: 100, width: 400, height: 300)

    XCTAssertEqual(
      WindowDisplayGeometry.index(ofScreenShowing: mostlyLeft, in: [left, right]), 0)
    XCTAssertEqual(
      WindowDisplayGeometry.index(ofScreenShowing: mostlyRight, in: [left, right]), 1)
    XCTAssertNil(WindowDisplayGeometry.index(ofScreenShowing: mostlyLeft, in: []))
  }

  func testAWindowOnNoDisplayAtAllStillHasSomewhereToMoveFrom() {
    let offscreen = CGRect(x: -4000, y: -4000, width: 300, height: 200)

    XCTAssertEqual(
      WindowDisplayGeometry.index(ofScreenShowing: offscreen, in: [left, right]), 0,
      "a window macOS has left off every display must not make the action do nothing")
  }

  func testAWindowKeepsItsPlaceAndProportionsOnTheNewDisplay() {
    // A window occupying the left quarter-ish of the large display: origin at 25%/20%,
    // half its width and a fifth of its height.
    let window = CGRect(x: 400, y: 200, width: 800, height: 200)

    let moved = WindowDisplayGeometry.frame(window, movingFrom: left, to: right)

    XCTAssertEqual(moved.minX, 1600 + 0.25 * 800, accuracy: 0.01)
    XCTAssertEqual(moved.minY, 0.2 * 600, accuracy: 0.01)
    XCTAssertEqual(moved.width, 0.5 * 800, accuracy: 0.01)
    XCTAssertEqual(moved.height, 0.2 * 600, accuracy: 0.01)
  }

  func testAWindowIsClampedInsideTheDisplayItLandsOn() {
    let full = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    let moved = WindowDisplayGeometry.frame(full, movingFrom: left, to: right)

    XCTAssertEqual(moved, right, "a window as large as its display stays as large as the next one")
    XCTAssertTrue(right.contains(moved))
  }

  func testAWindowHangingOffTheEdgeIsPulledBackOntoTheDisplay() {
    let hangingOff = CGRect(x: 1400, y: 800, width: 400, height: 400)

    let moved = WindowDisplayGeometry.frame(hangingOff, movingFrom: left, to: right)

    XCTAssertTrue(
      right.contains(moved),
      "the fraction of the way across is preserved until it would push the window off screen")
    XCTAssertEqual(moved.maxX, right.maxX, accuracy: 0.01)
    XCTAssertEqual(moved.maxY, right.maxY, accuracy: 0.01)
  }

  func testADisplayThatReportsNoAreaCentersTheWindowInsteadOfDividingByZero() {
    let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
    let window = CGRect(x: 0, y: 0, width: 400, height: 300)

    let moved = WindowDisplayGeometry.frame(window, movingFrom: degenerate, to: right)

    XCTAssertEqual(moved.midX, right.midX, accuracy: 0.01)
    XCTAssertEqual(moved.midY, right.midY, accuracy: 0.01)
    XCTAssertEqual(moved.size, window.size)
  }

  /// Right-to-left cycling is the whole action: from the left display the window lands on
  /// the right one, and from the right one it comes back.
  func testCyclingTwiceReturnsTheWindowToTheDisplayItStartedOn() {
    let screens = [left, right]
    let window = CGRect(x: 400, y: 200, width: 800, height: 200)

    let firstIndex = WindowDisplayGeometry.index(ofScreenShowing: window, in: screens)!
    let secondIndex = WindowDisplayGeometry.nextIndex(after: firstIndex, count: screens.count)!
    let onSecond = WindowDisplayGeometry.frame(
      window, movingFrom: screens[firstIndex], to: screens[secondIndex])
    let thirdIndex = WindowDisplayGeometry.nextIndex(after: secondIndex, count: screens.count)!
    let backOnFirst = WindowDisplayGeometry.frame(
      onSecond, movingFrom: screens[secondIndex], to: screens[thirdIndex])

    XCTAssertEqual(secondIndex, 1)
    XCTAssertEqual(thirdIndex, 0)
    XCTAssertEqual(
      WindowDisplayGeometry.index(ofScreenShowing: onSecond, in: screens), 1,
      "a window moved to the right display has to be found there on the next press")
    XCTAssertEqual(backOnFirst.minX, window.minX, accuracy: 0.01)
    XCTAssertEqual(backOnFirst.width, window.width, accuracy: 0.01)
  }
}
