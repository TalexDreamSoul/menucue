import AppKit
import Foundation
import XCTest
@testable import MenuCue

final class LaunchAtLoginTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()

        _ = NSApplication.shared
        suiteName = "MenuCueTests.LaunchAtLoginTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil

        super.tearDown()
    }

    func testRegisteredStatesIncludeEnabledAndApprovalRequiredOnly() {
        let cases: [(state: LaunchAtLoginState, isRegistered: Bool)] = [
            (.enabled, true),
            (.requiresApproval, true),
            (.disabled, false),
            (.unavailable, false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                testCase.state.isRegistered,
                testCase.isRegistered,
                "Expected \(testCase.state) registration state to be \(testCase.isRegistered)"
            )
        }
    }

    func testSuccessfulLaunchAtLoginChangesRefreshStateAndClearPreviousError() {
        let cases: [(name: String, requestedValue: Bool, initialState: LaunchAtLoginState, refreshedState: LaunchAtLoginState)] = [
            ("enable", true, .disabled, .enabled),
            ("disable", false, .enabled, .disabled)
        ]

        for testCase in cases {
            let service = FakeLaunchAtLoginService(state: testCase.initialState)
            service.stateAfterSetEnabled = testCase.refreshedState
            let model = makeModel(launchAtLoginService: service)
            model.launchAtLoginErrorMessage = "Previous error"

            model.setLaunchAtLoginEnabled(testCase.requestedValue)

            XCTAssertEqual(service.setEnabledRequests, [testCase.requestedValue], "\(testCase.name) should request exactly one matching service operation")
            XCTAssertEqual(model.launchAtLoginState, testCase.refreshedState, "\(testCase.name) should publish the service state after the operation")
            XCTAssertNil(model.launchAtLoginErrorMessage, "\(testCase.name) should clear an error after the service succeeds")
        }
    }

    func testFailedLaunchAtLoginChangeSurfacesErrorAndRefreshesActualState() {
        let service = FakeLaunchAtLoginService(state: .disabled)
        service.stateAfterSetEnabled = .requiresApproval
        service.setEnabledError = LaunchAtLoginTestError.operationDenied
        let model = makeModel(launchAtLoginService: service)

        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.setEnabledRequests, [true])
        XCTAssertEqual(model.launchAtLoginState, .requiresApproval)
        XCTAssertEqual(
            model.launchAtLoginErrorMessage,
            L10n.format(
                "Could not update Launch at Login: %@",
                LaunchAtLoginTestError.operationDenied.localizedDescription
            )
        )
    }

    func testExplicitStatusRefreshPublishesCurrentServiceState() {
        let service = FakeLaunchAtLoginService(state: .disabled)
        let model = makeModel(launchAtLoginService: service)
        service.state = .unavailable

        model.refreshLaunchAtLoginState()

        XCTAssertEqual(model.launchAtLoginState, .unavailable)
    }

    func testOpeningLoginItemsSettingsDelegatesExactlyOnce() {
        let service = FakeLaunchAtLoginService(state: .requiresApproval)
        let model = makeModel(launchAtLoginService: service)

        model.openLoginItemsSettings()

        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
    }

    private func makeModel(launchAtLoginService: LaunchAtLoginManaging) -> AppModel {
        AppModel(
            settingsStore: SettingsStore(defaults: defaults),
            calendarService: CalendarService(),
            appearanceService: AppearanceService(),
            launchAtLoginService: launchAtLoginService
        )
    }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginManaging {
    var state: LaunchAtLoginState
    var stateAfterSetEnabled: LaunchAtLoginState?
    var setEnabledError: Error?
    private(set) var setEnabledRequests: [Bool] = []
    private(set) var openSystemSettingsCallCount = 0

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledRequests.append(enabled)
        if let stateAfterSetEnabled {
            state = stateAfterSetEnabled
        }
        if let setEnabledError {
            throw setEnabledError
        }
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

private enum LaunchAtLoginTestError: LocalizedError {
    case operationDenied

    var errorDescription: String? {
        switch self {
        case .operationDenied:
            return "Launch at Login registration was denied."
        }
    }
}

