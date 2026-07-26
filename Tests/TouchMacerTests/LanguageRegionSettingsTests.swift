import XCTest
@testable import TouchMacer

final class LanguageRegionSettingsTests: XCTestCase {
  func testTimeZoneSearchMatchesIdentifierAndLocalizedName() {
    let identifiers = ["America/Los_Angeles", "Asia/Shanghai", "Europe/London"]

    XCTAssertEqual(
      SystemTimeZoneCatalog.options(
        matching: "shanghai",
        locale: Locale(identifier: "en"),
        identifiers: identifiers
      ).map(\.id),
      ["Asia/Shanghai"]
    )
    XCTAssertEqual(
      SystemTimeZoneCatalog.options(
        matching: "Los Angeles",
        locale: Locale(identifier: "en"),
        identifiers: identifiers
      ).map(\.id),
      ["America/Los_Angeles"]
    )
  }

  func testApplyActionRejectsInvalidAndUnchangedTargets() {
    XCTAssertEqual(
      SystemTimeZoneApplyPolicy.action(
        registrationState: .enabled,
        supportsSystemTimeZone: true,
        targetIdentifier: "Invalid/Zone",
        currentIdentifier: "Europe/London",
        isWorking: false
      ),
      .disabled
    )
    XCTAssertEqual(
      SystemTimeZoneApplyPolicy.action(
        registrationState: .enabled,
        supportsSystemTimeZone: true,
        targetIdentifier: "Europe/London",
        currentIdentifier: "Europe/London",
        isWorking: false
      ),
      .disabled
    )
  }

  func testApplyActionProvidesHelperRemediationBeforeRPC() {
    XCTAssertEqual(
      SystemTimeZoneApplyPolicy.action(
        registrationState: .notRegistered,
        supportsSystemTimeZone: false,
        targetIdentifier: "Asia/Shanghai",
        currentIdentifier: "Europe/London",
        isWorking: false
      ),
      .installHelper
    )
    XCTAssertEqual(
      SystemTimeZoneApplyPolicy.action(
        registrationState: .requiresApproval,
        supportsSystemTimeZone: false,
        targetIdentifier: "Asia/Shanghai",
        currentIdentifier: "Europe/London",
        isWorking: false
      ),
      .openHelperSettings
    )
    XCTAssertEqual(
      SystemTimeZoneApplyPolicy.action(
        registrationState: .enabled,
        supportsSystemTimeZone: false,
        targetIdentifier: "Asia/Shanghai",
        currentIdentifier: "Europe/London",
        isWorking: false
      ),
      .refreshHelper
    )
  }

  func testValidEnabledHelperCanApplyTimeZone() {
    XCTAssertEqual(
      SystemTimeZoneApplyPolicy.action(
        registrationState: .enabled,
        supportsSystemTimeZone: true,
        targetIdentifier: "Asia/Shanghai",
        currentIdentifier: "Europe/London",
        isWorking: false
      ),
      .apply
    )
  }

  func testUneditedTargetFollowsExternalSystemTimeZoneChanges() {
    var selection = SystemTimeZoneSelectionState(currentIdentifier: "Europe/London")

    selection.observe("Asia/Shanghai")

    XCTAssertEqual(selection.observedIdentifier, "Asia/Shanghai")
    XCTAssertEqual(selection.targetIdentifier, "Asia/Shanghai")
    XCTAssertFalse(selection.hasUserEditedTarget)
  }

  func testEditedTargetIsPreservedUntilApplySucceeds() {
    var selection = SystemTimeZoneSelectionState(currentIdentifier: "Europe/London")
    selection.select("Asia/Shanghai")

    selection.observe("America/Los_Angeles")

    XCTAssertEqual(selection.observedIdentifier, "America/Los_Angeles")
    XCTAssertEqual(selection.targetIdentifier, "Asia/Shanghai")
    XCTAssertTrue(selection.hasUserEditedTarget)

    selection.completeApply(
      observedIdentifier: "Asia/Shanghai",
      requestedIdentifier: "Asia/Shanghai"
    )
    XCTAssertEqual(selection.observedIdentifier, "Asia/Shanghai")
    XCTAssertEqual(selection.targetIdentifier, "Asia/Shanghai")
    XCTAssertFalse(selection.hasUserEditedTarget)
  }

  func testCompletedRequestDoesNotOverwriteNewerUserTarget() {
    var selection = SystemTimeZoneSelectionState(currentIdentifier: "Europe/London")
    selection.select("Asia/Shanghai")
    let requestedIdentifier = selection.targetIdentifier
    selection.select("America/Los_Angeles")

    selection.completeApply(
      observedIdentifier: "Asia/Shanghai",
      requestedIdentifier: requestedIdentifier
    )

    XCTAssertEqual(selection.observedIdentifier, "Asia/Shanghai")
    XCTAssertEqual(selection.targetIdentifier, "America/Los_Angeles")
    XCTAssertTrue(selection.hasUserEditedTarget)
  }

  func testGlobalLanguageLinkUsesSupportedSystemSettingsDeepLink() {
    XCTAssertEqual(
      LanguageRegionLinks.systemLanguageSettings.absoluteString,
      "x-apple.systempreferences:com.apple.Localization-Settings.extension"
    )
  }
}
