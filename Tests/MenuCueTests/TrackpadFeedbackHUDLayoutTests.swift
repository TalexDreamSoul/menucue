import XCTest

@testable import MenuCue

/// The panel used to be placed relative to the pointer, which put a volume readout
/// wherever the hand happened to leave the cursor. It now sits at the bottom of the screen
/// the pointer is on — the pointer picks the display and contributes nothing else, which is
/// why none of these cases mention it.
final class TrackpadFeedbackHUDLayoutTests: XCTestCase {
  private let panel = TrackpadFeedbackHUDLayout.panelSize

  /// The readout has two shapes: a labelled bar in a column beside an icon, and a plain
  /// centred sentence. Both have to stay inside the panel, and the bar has to line up under
  /// the text rather than beside it.
  func testBothReadoutShapesStayInsideThePanel() {
    let size = TrackpadFeedbackHUDLayout.panelSize
    let bounds = CGRect(origin: .zero, size: size)

    let withLevel = TrackpadFeedbackHUDLayout.contentFrames(showingLevel: true)
    XCTAssertTrue(bounds.contains(withLevel.icon), "icon")
    XCTAssertTrue(bounds.contains(withLevel.label), "label")
    XCTAssertTrue(bounds.contains(withLevel.bar), "bar")
    XCTAssertEqual(withLevel.bar.minX, withLevel.label.minX, "the bar sits under the text")
    XCTAssertEqual(withLevel.bar.width, withLevel.label.width, accuracy: 0.001)
    XCTAssertLessThan(withLevel.bar.maxY, withLevel.label.minY, "the bar sits below the text")
    XCTAssertLessThan(withLevel.icon.maxX, withLevel.label.minX, "the icon takes the left column")

    let textOnly = TrackpadFeedbackHUDLayout.contentFrames(showingLevel: false)
    XCTAssertTrue(bounds.contains(textOnly.label), "label")
    XCTAssertGreaterThan(
      textOnly.label.width,
      withLevel.label.width,
      "a sentence with no icon beside it gets the whole width"
    )
  }

  /// `visibleFrame` is the whole story: whichever edge the Dock takes, the usable area
  /// shrinks there and the panel follows without naming an edge.
  func testThePanelSitsBottomCentredForEveryDockPosition() {
    let cases: [(name: String, visibleFrame: CGRect, expected: CGPoint)] = [
      (
        name: "Dock along the bottom lifts the panel above it",
        visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 985),
        expected: CGPoint(x: 842, y: 166)
      ),
      (
        name: "Dock on the left shifts the centre right",
        visibleFrame: CGRect(x: 80, y: 0, width: 1840, height: 1055),
        expected: CGPoint(x: 882, y: 96)
      ),
      (
        name: "Dock on the right shifts the centre left",
        visibleFrame: CGRect(x: 0, y: 0, width: 1840, height: 1055),
        expected: CGPoint(x: 802, y: 96)
      ),
    ]

    for testCase in cases {
      XCTAssertEqual(
        TrackpadFeedbackHUDLayout.origin(panelSize: panel, in: testCase.visibleFrame),
        testCase.expected,
        testCase.name
      )
    }
  }

  /// AppKit reports every screen in one global space where the main display starts at the
  /// origin, so a second display carries an offset the panel has to keep rather than
  /// normalize away.
  func testASecondDisplayIsPlacedInItsOwnGlobalCoordinates() {
    let toTheLeft = TrackpadFeedbackHUDLayout.origin(
      panelSize: panel,
      in: CGRect(x: -1440, y: 0, width: 1440, height: 875)
    )
    let above = TrackpadFeedbackHUDLayout.origin(
      panelSize: panel,
      in: CGRect(x: 200, y: 1080, width: 1440, height: 875)
    )

    XCTAssertEqual(toTheLeft, CGPoint(x: -838, y: 96), "a display left of the main one sits at negative x")
    XCTAssertEqual(above, CGPoint(x: 802, y: 1176), "the inset is measured from that display's own bottom")
  }

  func testTheOriginIsIndependentOfTheOtherScreensInPlay() {
    let sameScreen = CGRect(x: 0, y: 70, width: 1920, height: 985)

    XCTAssertEqual(
      TrackpadFeedbackHUDLayout.origin(panelSize: panel, in: sameScreen),
      TrackpadFeedbackHUDLayout.origin(panelSize: panel, in: sameScreen),
      "placement reads one screen and nothing else, so it is the same on every show"
    )
  }

  /// A panel that cannot fit is the case where centring and clamping disagree. Landing
  /// half off-screen would be worse than sitting in the corner.
  func testAPanelTooLargeForTheUsableAreaStaysInsideIt() {
    let visibleFrame = CGRect(x: 0, y: 70, width: 1920, height: 985)

    let tooWide = TrackpadFeedbackHUDLayout.origin(
      panelSize: CGSize(width: 2000, height: 48),
      in: visibleFrame
    )
    let shortScreen = TrackpadFeedbackHUDLayout.origin(
      panelSize: panel,
      in: CGRect(x: 0, y: 70, width: 1920, height: 100)
    )

    XCTAssertEqual(tooWide.x, visibleFrame.minX, "a panel wider than the screen starts at its edge")
    XCTAssertEqual(
      shortScreen.y, 106,
      "the inset gives way so the whole panel stays on a screen shorter than the inset"
    )
  }
}
