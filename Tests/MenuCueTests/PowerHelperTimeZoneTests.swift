import XCTest
@testable import MenuCue
import MenuCueHelperProtocol

final class PowerHelperTimeZoneTests: XCTestCase {
    func testOutdatedHelperStateRequiresExplicitRefreshBeforeUse() {
        let state = PowerHelperRegistrationState.refreshRequired

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.title, "Update Required")
        XCTAssertTrue(state.detail.contains("Refresh"))
    }

    func testProtocolAdvertisesVersionedSystemTimeZoneCapability() {
        XCTAssertGreaterThanOrEqual(PowerHelperProtocolInfo.currentVersion, 2)
        XCTAssertTrue(
            PowerHelperProtocolInfo.currentCapabilities.contains(.systemTimeZone)
        )
    }

    func testSystemTimeZoneCommandAllowsOnlyKnownIANAIdentifiers() {
        XCTAssertEqual(
            SystemTimeZoneCommand.arguments(for: "America/New_York"),
            ["-settimezone", "America/New_York"]
        )
        XCTAssertNil(SystemTimeZoneCommand.arguments(for: ""))
        XCTAssertNil(SystemTimeZoneCommand.arguments(for: "America/New_York; rm -rf /"))
        XCTAssertNil(SystemTimeZoneCommand.arguments(for: "../etc/localtime"))
    }

    func testSystemTimeZoneCommandParsesObservedIdentifier() {
        XCTAssertEqual(
            SystemTimeZoneCommand.observedIdentifier(from: "Time Zone: Asia/Shanghai\n"),
            "Asia/Shanghai"
        )
        XCTAssertEqual(
            SystemTimeZoneCommand.observedIdentifier(
                from: "You must be root to run this tool.\nTime Zone: Europe/London\n"
            ),
            "Europe/London"
        )
        XCTAssertNil(SystemTimeZoneCommand.observedIdentifier(from: "Time Zone:\n"))
        XCTAssertNil(SystemTimeZoneCommand.observedIdentifier(from: "unexpected output"))
    }

    func testObservedIdentifierMustMatchRequestedTarget() {
        XCTAssertTrue(
            SystemTimeZoneCommand.matches(
                requestedIdentifier: "Asia/Shanghai",
                observedOutput: "Time Zone: Asia/Shanghai"
            )
        )
        XCTAssertFalse(
            SystemTimeZoneCommand.matches(
                requestedIdentifier: "Asia/Shanghai",
                observedOutput: "Time Zone: Europe/London"
            )
        )
    }
}
