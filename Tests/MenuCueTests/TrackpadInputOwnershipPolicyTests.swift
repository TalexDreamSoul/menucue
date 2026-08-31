import CoreGraphics
import XCTest

@testable import MenuCue

/// AirPlay mirroring still renders locally, but synthesized local input cannot control the
/// receiver, so only a pointer on the mirror set pauses gesture automation.
final class TrackpadInputOwnershipPolicyTests: XCTestCase {
  func testOnlyAPointerOnTheMirrorSetIsOwnedByTheMirroredDisplay() {
    let mirroredDisplay = CGDirectDisplayID(42)
    let localDisplay = CGDirectDisplayID(43)
    let cases: [(name: String, pointerDisplayID: CGDirectDisplayID?, expected: TrackpadInputOwnership)] = [
      ("mirrored display", mirroredDisplay, .mirroredDisplay),
      ("non-mirrored display", localDisplay, .local),
      ("unknown display", nil, .local),
    ]

    for testCase in cases {
      XCTAssertEqual(
        TrackpadInputOwnershipPolicy.ownership(
          pointerDisplayID: testCase.pointerDisplayID,
          isInMirrorSet: { $0 == mirroredDisplay }
        ),
        testCase.expected,
        testCase.name
      )
    }
  }
}
