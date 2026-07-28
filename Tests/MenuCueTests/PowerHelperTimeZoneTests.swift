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
        XCTAssertGreaterThanOrEqual(PowerHelperProtocolInfo.currentVersion, 3)
        XCTAssertTrue(
            PowerHelperProtocolInfo.currentCapabilities.contains(.systemTimeZone)
        )
        XCTAssertTrue(
            PowerHelperProtocolInfo.currentCapabilities.contains(.managedPowerSettings)
        )
        XCTAssertTrue(
            PowerHelperProtocolInfo.currentCapabilities.contains(.processControl)
        )
    }

    func testManagedPowerSettingCommandAllowsOnlyTypedSettingsAndSources() {
        XCTAssertEqual(
            ManagedPowerSettingCommand.arguments(
                settingRawValue: ManagedPowerSetting.powerNap.rawValue,
                sourceRawValue: ManagedPowerSource.battery.rawValue,
                enabled: true
            ),
            ["-b", "powernap", "1"]
        )
        XCTAssertEqual(
            ManagedPowerSettingCommand.arguments(
                settingRawValue: ManagedPowerSetting.wakeOnNetwork.rawValue,
                sourceRawValue: ManagedPowerSource.ac.rawValue,
                enabled: false
            ),
            ["-c", "womp", "0"]
        )
        XCTAssertNil(
            ManagedPowerSettingCommand.arguments(
                settingRawValue: 999,
                sourceRawValue: ManagedPowerSource.all.rawValue,
                enabled: true
            )
        )
        XCTAssertNil(
            ManagedPowerSettingCommand.arguments(
                settingRawValue: ManagedPowerSetting.standby.rawValue,
                sourceRawValue: 999,
                enabled: true
            )
        )
    }

    func testManagedPowerSettingReadBackRequiresEveryPresentProfile() {
        let missingBatteryValue = """
        Battery Power:
         standby 1
        AC Power:
         powernap 0
        """
        XCTAssertFalse(
            ManagedPowerSettingCommand.observedValueMatches(
                settingRawValue: ManagedPowerSetting.powerNap.rawValue,
                sourceRawValue: ManagedPowerSource.all.rawValue,
                enabled: false,
                customOutput: missingBatteryValue
            )
        )

        let matching = """
        Battery Power:
         powernap 0
        AC Power:
         powernap 0
        """
        XCTAssertTrue(
            ManagedPowerSettingCommand.observedValueMatches(
                settingRawValue: ManagedPowerSetting.powerNap.rawValue,
                sourceRawValue: ManagedPowerSource.all.rawValue,
                enabled: false,
                customOutput: matching
            )
        )
    }

    func testProcessControlContractPreservesMicrosecondsAndRejectsNiceBoundaryNoOps() {
        XCTAssertEqual(
            ProcessControlCommand.startTimeMicroseconds(1_000.123456),
            1_000_123_456
        )
        XCTAssertEqual(ProcessControlCommand.relativeNiceTarget(current: 0, delta: -1), -1)
        XCTAssertEqual(ProcessControlCommand.relativeNiceTarget(current: 0, delta: 1), 1)
        XCTAssertNil(ProcessControlCommand.relativeNiceTarget(current: 19, delta: 1))
        XCTAssertNil(ProcessControlCommand.relativeNiceTarget(current: -20, delta: -1))
        XCTAssertNil(ProcessControlCommand.relativeNiceTarget(current: 0, delta: 0))
        XCTAssertNil(ProcessControlCommand.relativeNiceTarget(current: 0, delta: 2))
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
