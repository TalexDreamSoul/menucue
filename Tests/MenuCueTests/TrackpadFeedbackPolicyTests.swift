import XCTest

@testable import MenuCue

final class TrackpadFeedbackPolicyTests: XCTestCase {
  func testHUDVisibilityRespectsContinuousFailureAndGlobalEnablement() {
    let cases: [(
      name: String,
      isEnabled: Bool,
      isContinuous: Bool,
      isFailure: Bool,
      expected: Bool
    )] = [
      (
        name: "enabled continuous success is hidden",
        isEnabled: true,
        isContinuous: true,
        isFailure: false,
        expected: false
      ),
      (
        name: "enabled continuous failure is shown",
        isEnabled: true,
        isContinuous: true,
        isFailure: true,
        expected: true
      ),
      (
        name: "enabled discrete success is shown",
        isEnabled: true,
        isContinuous: false,
        isFailure: false,
        expected: true
      ),
      (
        name: "disabled continuous failure is hidden",
        isEnabled: false,
        isContinuous: true,
        isFailure: true,
        expected: false
      ),
      (
        name: "disabled discrete success is hidden",
        isEnabled: false,
        isContinuous: false,
        isFailure: false,
        expected: false
      ),
    ]

    for testCase in cases {
      XCTAssertEqual(
        TrackpadFeedbackPolicy.shouldShowHUD(
          isEnabled: testCase.isEnabled,
          isContinuous: testCase.isContinuous,
          isFailure: testCase.isFailure
        ),
        testCase.expected,
        testCase.name
      )
    }
  }
}
