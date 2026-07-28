import XCTest
@testable import MenuCue

final class QuickActionAuthorizationTests: XCTestCase {
  func testLockScreenRequestsAccessibilityBeforeRunningSystemEvents() {
    let requester = AccessibilityPermissionRequesterStub(isGranted: false)
    let service = QuickActionService(
      appearanceService: AppearanceService(),
      accessibilityPermissionRequester: requester
    )

    service.perform(.builtIn(.lockScreen))

    XCTAssertEqual(requester.requestCount, 1)
    XCTAssertEqual(
      service.feedbackMessage,
      L10n.string("Allow Accessibility access to use Lock Screen, then try again.")
    )
  }

  func testOnlyUnresolvedHelperStatesNeedProminentRemediation() {
    let unresolvedStates: [PowerHelperRegistrationState] = [
      .unavailable("Missing bundle"),
      .notRegistered,
      .requiresApproval,
      .refreshRequired,
      .failed("Registration failed"),
    ]

    XCTAssertTrue(unresolvedStates.allSatisfy(\.needsProminentRemediation))
    XCTAssertFalse(PowerHelperRegistrationState.enabled.needsProminentRemediation)
  }
}

private final class AccessibilityPermissionRequesterStub: AccessibilityPermissionRequesting {
  private(set) var requestCount = 0
  private let isGranted: Bool

  init(isGranted: Bool) {
    self.isGranted = isGranted
  }

  func requestAccess() -> Bool {
    requestCount += 1
    return isGranted
  }
}
