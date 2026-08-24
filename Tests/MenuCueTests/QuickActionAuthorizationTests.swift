import Foundation
import XCTest
@testable import MenuCue

final class QuickActionAuthorizationTests: XCTestCase {
  func testLockScreenDeniedAccessibilitySurfacesSettingsRemediationWithoutPrompt() {
    let settingsURL = URL(string: "x-test://accessibility")!
    let requester = AccessibilityPermissionRequesterStub(
      status: .denied,
      settingsURL: settingsURL
    )
    let service = QuickActionService(
      appearanceService: AppearanceService(),
      accessibilityPermissionRequester: requester
    )
    let availability = service.item(for: .builtIn(.lockScreen)).state.availability

    service.perform(.builtIn(.lockScreen))

    let message = L10n.string(
      "Lock Screen requires Accessibility access. Open System Settings and turn on MenuCue under Privacy & Security → Accessibility."
    )
    XCTAssertEqual(requester.requestCount, 0)
    XCTAssertFalse(availability.isAvailable)
    XCTAssertEqual(availability.reason, message)
    XCTAssertEqual(availability.settingsURL, settingsURL)
    XCTAssertEqual(service.feedbackMessage, message)
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

  func testCleanKeyboardDistinguishesAccessibilityDenialFromEventTapFailure() {
    let accessibilityURL = URL(string: "x-test://accessibility")!
    let deniedService = QuickActionService(
      appearanceService: AppearanceService(),
      accessibilityPermissionRequester: AccessibilityPermissionRequesterStub(
        status: .denied,
        settingsURL: accessibilityURL
      )
    )

    let deniedAvailability = deniedService.item(for: .builtIn(.cleanKeyboard)).state.availability

    XCTAssertFalse(deniedAvailability.isAvailable)
    XCTAssertEqual(
      deniedAvailability.reason,
      L10n.string(
        "Clean Keyboard requires Accessibility access. Open System Settings and turn on MenuCue under Privacy & Security → Accessibility."
      )
    )
    XCTAssertEqual(deniedAvailability.settingsURL, accessibilityURL)

    let eventTapUnavailableService = QuickActionService(
      appearanceService: AppearanceService(),
      accessibilityPermissionRequester: AccessibilityPermissionRequesterStub(
        status: .granted,
        settingsURL: accessibilityURL
      ),
      keyboardEventBlockerFactory: { KeyboardEventBlockerStub(result: .eventTapUnavailable) }
    )
    eventTapUnavailableService.perform(.builtIn(.cleanKeyboard))

    let eventTapAvailability = eventTapUnavailableService.item(for: .builtIn(.cleanKeyboard)).state.availability

    XCTAssertEqual(
      eventTapUnavailableService.feedbackMessage,
      L10n.string(
        "Clean Keyboard could not start because macOS did not make the keyboard event tap available."
      )
    )
    XCTAssertTrue(eventTapAvailability.isAvailable)
    XCTAssertNil(eventTapAvailability.reason)
    XCTAssertNil(eventTapAvailability.settingsURL)
  }

  func testCleanKeyboardEventTapFailureCanRetryWithoutSystemSettingsRemediation() {
    let accessibilityURL = URL(string: "x-test://accessibility")!
    let requester = AccessibilityPermissionRequesterStub(status: .granted, settingsURL: accessibilityURL)
    let blocker = SequencedKeyboardEventBlockerStub(
      results: [.eventTapUnavailable, .accessibilityDenied]
    )
    let service = QuickActionService(
      appearanceService: AppearanceService(),
      accessibilityPermissionRequester: requester,
      keyboardEventBlockerFactory: { blocker }
    )

    service.perform(.builtIn(.cleanKeyboard))
    let afterFailure = service.item(for: .builtIn(.cleanKeyboard)).state.availability

    XCTAssertTrue(afterFailure.isAvailable)
    XCTAssertNil(afterFailure.settingsURL)

    requester.setStatus(.denied)
    service.perform(.builtIn(.cleanKeyboard))

    XCTAssertEqual(
      service.feedbackMessage,
      L10n.string(
        "Clean Keyboard requires Accessibility access. Open System Settings and turn on MenuCue under Privacy & Security → Accessibility."
      )
    )
  }
}

private final class AccessibilityPermissionRequesterStub: AccessibilityPermissionRequesting {
  private(set) var requestCount = 0
  private var statusValue: AccessibilityPermissionStatus
  private let settingsURL: URL

  init(status: AccessibilityPermissionStatus, settingsURL: URL) {
    self.statusValue = status
    self.settingsURL = settingsURL
  }

  var status: AccessibilityPermissionStatus { statusValue }

  func setStatus(_ status: AccessibilityPermissionStatus) {
    statusValue = status
  }

  var accessibilitySettingsURL: URL { settingsURL }

  func requestAccess() -> Bool {
    requestCount += 1
    return statusValue == .granted
  }
}

private final class KeyboardEventBlockerStub: KeyboardEventBlocking {
  private let result: KeyboardEventBlockerStartResult

  init(result: KeyboardEventBlockerStartResult) {
    self.result = result
  }

  func start(
    accessibilityPermissionRequester: AccessibilityPermissionRequesting,
    onEscapeHeld: @escaping () -> Void
  ) -> KeyboardEventBlockerStartResult {
    result
  }

  func stop() {}
}

private final class SequencedKeyboardEventBlockerStub: KeyboardEventBlocking {
  private var results: [KeyboardEventBlockerStartResult]

  init(results: [KeyboardEventBlockerStartResult]) {
    self.results = results
  }

  func start(
    accessibilityPermissionRequester: AccessibilityPermissionRequesting,
    onEscapeHeld: @escaping () -> Void
  ) -> KeyboardEventBlockerStartResult {
    results.removeFirst()
  }

  func stop() {}
}
