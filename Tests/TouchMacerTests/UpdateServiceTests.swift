import Sparkle
import XCTest
@testable import TouchMacer

@MainActor
final class UpdateServiceTests: XCTestCase {
    func testAutomaticPreferenceControlsChecksAndDownloadsTogether() {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = true
        engine.automaticallyDownloadsUpdates = true
        let service = UpdateService(engine: engine)

        XCTAssertTrue(service.automaticUpdatesEnabled)

        service.setAutomaticUpdatesEnabled(false)

        XCTAssertFalse(engine.automaticallyChecksForUpdates)
        XCTAssertFalse(engine.automaticallyDownloadsUpdates)
        XCTAssertFalse(service.automaticUpdatesEnabled)

        service.setAutomaticUpdatesEnabled(true)

        XCTAssertTrue(engine.automaticallyChecksForUpdates)
        XCTAssertTrue(engine.automaticallyDownloadsUpdates)
        XCTAssertTrue(service.automaticUpdatesEnabled)
    }

    func testManualCheckRemainsAvailableWhenSchedulingIsDisabled() {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = false
        engine.automaticallyDownloadsUpdates = false
        engine.canCheckForUpdates = true
        let service = UpdateService(engine: engine)

        service.checkForUpdates()

        XCTAssertEqual(engine.checkCount, 1)
        XCTAssertEqual(service.status, .checking)
    }

    func testNoUpdateReasonDistinguishesCurrentFromIncompatibleRelease() {
        let currentError = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue),
            userInfo: [
                SPUNoUpdateFoundReasonKey: NSNumber(
                    value: SPUNoUpdateFoundReason.onLatestVersion.rawValue
                )
            ]
        )
        XCTAssertEqual(
            SparkleUpdateStatusResolver.noUpdateStatus(currentError),
            .current
        )

        let incompatibleError = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue),
            userInfo: [
                NSLocalizedDescriptionKey: "This update requires a newer macOS version.",
                SPUNoUpdateFoundReasonKey: NSNumber(
                    value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue
                ),
            ]
        )
        XCTAssertEqual(
            SparkleUpdateStatusResolver.noUpdateStatus(incompatibleError),
            .failed(message: "This update requires a newer macOS version.")
        )
    }

    func testCanceledInstallationReturnsUpdaterToIdle() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.installationCanceledError.rawValue)
        )

        XCTAssertEqual(
            SparkleUpdateStatusResolver.cycleErrorStatus(error),
            .idle
        )
    }

    func testEngineChangesRefreshStateAndPublishLifecycleStatus() {
        let checkDate = Date(timeIntervalSinceReferenceDate: 42)
        let engine = FakeUpdateEngine()
        let service = UpdateService(engine: engine)

        engine.canCheckForUpdates = false
        engine.lastUpdateCheckDate = checkDate
        engine.emitStateChange()
        engine.emitStatus(.downloaded(version: "0.4.1"))

        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertEqual(service.lastUpdateCheckDate, checkDate)
        XCTAssertEqual(service.status, .downloaded(version: "0.4.1"))
    }
}

@MainActor
private final class FakeUpdateEngine: UpdateEngine {
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var stateDidChange: (() -> Void)?
    var statusDidChange: ((UpdateStatus) -> Void)?
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }

    func emitStateChange() {
        stateDidChange?()
    }

    func emitStatus(_ status: UpdateStatus) {
        statusDidChange?(status)
    }
}
