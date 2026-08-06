import AppKit
import XCTest

@testable import MenuCue

final class CalendarPermissionAdvisorTests: XCTestCase {
  func testGrantedAccessOffersNoGuidance() {
    XCTAssertNil(
      CalendarPermissionAdvisor.guidance(for: .fullAccess, promptSuppressed: false)
    )
    XCTAssertNil(
      CalendarPermissionAdvisor.guidance(for: .fullAccess, promptSuppressed: true),
      "a stale suppression flag must not outlive an granted state"
    )
  }

  func testFirstRunAsksTheSystemRatherThanSendingUsersToSettings() {
    let guidance = CalendarPermissionAdvisor.guidance(
      for: .notDetermined,
      promptSuppressed: false
    )

    XCTAssertEqual(guidance?.action, .request)
  }

  /// The case the whole type exists for: same state, different instruction, because the
  /// request already came back without moving it.
  func testSuppressedPromptRoutesToSystemSettings() {
    let guidance = CalendarPermissionAdvisor.guidance(
      for: .notDetermined,
      promptSuppressed: true
    )

    XCTAssertEqual(guidance?.action, .openSettings)
    XCTAssertNotEqual(
      guidance?.message,
      CalendarPermissionAdvisor.guidance(for: .notDetermined, promptSuppressed: false)?.message,
      "both undecided states would otherwise read identically to the user"
    )
  }

  func testDeniedAndRestrictedRouteToSystemSettings() {
    XCTAssertEqual(
      CalendarPermissionAdvisor.guidance(for: .denied, promptSuppressed: false)?.action,
      .openSettings
    )
    XCTAssertEqual(
      CalendarPermissionAdvisor.guidance(for: .restricted, promptSuppressed: false)?.action,
      .openSettings
    )
  }

  /// Write-only can still be escalated by a fresh request, so it must keep the ask.
  func testWriteOnlyAndUnknownKeepAsking() {
    XCTAssertEqual(
      CalendarPermissionAdvisor.guidance(for: .writeOnly, promptSuppressed: false)?.action,
      .request
    )
    XCTAssertEqual(
      CalendarPermissionAdvisor.guidance(for: .unknown("future"), promptSuppressed: false)?.action,
      .request
    )
  }

  func testEveryActionCarriesALocalizedButtonTitle() {
    for action in [CalendarPermissionAction.request, .openSettings] {
      XCTAssertFalse(action.buttonTitle.isEmpty)
    }
  }

  func testPrivacyLinkTargetsTheCalendarsPane() {
    XCTAssertEqual(
      CalendarPermissionLinks.systemCalendarSettings.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )
  }
}

final class CalendarPermissionRefreshTests: XCTestCase {
  /// Returning from System Settings is the only signal that a permission changed —
  /// EventKit posts nothing when TCC flips.
  func testReturningToTheAppRefreshesCalendarState() {
    XCTAssertTrue(
      CalendarRefreshController.observedNames.contains(
        NSApplication.didBecomeActiveNotification
      )
    )
  }
}
