import AppKit
import Foundation
import XCTest
@testable import MenuCue

final class PreferenceSyncServiceTests: XCTestCase {
    private let token = Data("stable-identity-token".utf8)
    private let oldDate = Date(timeIntervalSinceReferenceDate: 100)
    private let newDate = Date(timeIntervalSinceReferenceDate: 200)

    func testUnavailableEntitlementKeepsSyncLocalOnly() {
        let cloud = InMemoryPreferenceCloudStore()
        let service = PreferenceSyncService(
            store: cloud,
            notificationCenter: NotificationCenter(),
            isEntitled: false,
            identityTokenDataProvider: { self.token }
        )
        service.configure(
            localEnvelopeProvider: { [self] in
                [.overviewTimeZone: envelope(field: .overviewTimeZone, date: newDate, value: .overviewTimeZone("Asia/Tokyo"))]
            },
            importHandler: { _, _ in XCTFail("Unavailable sync must not import cloud preferences") }
        )

        service.start(enabled: true, onboardingCompleted: true, storedIdentityToken: token)
        service.completeOnboarding(enable: true)

        XCTAssertEqual(service.status, .unavailable)
        XCTAssertNil(cloud.data(forKey: cloudKey(for: .overviewTimeZone)))
    }

    func testOnboardingCanRemainDisabledOrEnableInitialLocalUpload() throws {
        let cloud = InMemoryPreferenceCloudStore()
        let service = entitledService(cloud: cloud)
        let local = envelope(field: .overviewTimeZone, date: newDate, value: .overviewTimeZone("Asia/Tokyo"))
        service.configure(localEnvelopeProvider: { [.overviewTimeZone: local] }, importHandler: { _, _ in })

        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        XCTAssertEqual(service.status, .needsOnboarding)

        service.completeOnboarding(enable: false)
        XCTAssertEqual(service.status, .disabled)

        service.completeOnboarding(enable: true)
        assertSynced(service.status)
        XCTAssertEqual(try storedEnvelope(in: cloud, field: .overviewTimeZone), local)
    }

    func testFirstSourceDecisionImportsCloudOnlyAfterExplicitCloudChoice() throws {
        let cloud = InMemoryPreferenceCloudStore()
        let remote = envelope(field: .overviewTimeZone, date: newDate, value: .overviewTimeZone("Europe/London"))
        cloud.setData(try JSONEncoder().encode(remote), forKey: cloudKey(for: .overviewTimeZone))
        let service = entitledService(cloud: cloud)
        var imported: [(envelopes: [PortableSettingEnvelope], force: Bool)] = []
        service.configure(
            localEnvelopeProvider: { [self] in
                [.overviewTimeZone: envelope(field: .overviewTimeZone, date: oldDate, value: .overviewTimeZone("Asia/Tokyo"))]
            },
            importHandler: { envelopes, force in imported.append((envelopes, force)) }
        )

        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        service.completeOnboarding(enable: true)

        XCTAssertEqual(service.status, .needsSourceDecision(.initialMerge))
        XCTAssertTrue(imported.isEmpty)

        service.chooseCloudSettings()

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].envelopes, [remote])
        XCTAssertTrue(imported[0].force)
        assertSynced(service.status)
    }

    func testLocalChangesUseIndependentCloudEnvelopes() throws {
        let cloud = InMemoryPreferenceCloudStore()
        let service = entitledService(cloud: cloud)
        let overview = envelope(field: .overviewTimeZone, date: oldDate, value: .overviewTimeZone("Asia/Tokyo"))
        let interval = envelope(field: .statusBarSwitchInterval, date: newDate, value: .statusBarSwitchInterval(12))
        service.configure(
            localEnvelopeProvider: { [.overviewTimeZone: overview, .statusBarSwitchInterval: interval] },
            importHandler: { _, _ in }
        )

        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        service.completeOnboarding(enable: true)

        XCTAssertEqual(try storedEnvelope(in: cloud, field: .overviewTimeZone), overview)
        XCTAssertEqual(try storedEnvelope(in: cloud, field: .statusBarSwitchInterval), interval)

        let updatedInterval = envelope(
            field: .statusBarSwitchInterval,
            date: newDate.addingTimeInterval(1),
            value: .statusBarSwitchInterval(8)
        )
        service.publishLocalChanges([updatedInterval])

        XCTAssertEqual(try storedEnvelope(in: cloud, field: .overviewTimeZone), overview)
        XCTAssertEqual(try storedEnvelope(in: cloud, field: .statusBarSwitchInterval), updatedInterval)
    }

    func testLegacyOverviewCloudEnvelopeStillAppliesToAnchorAndExportsOldWireName() throws {
        let legacy = Data("""
        {"schemaVersion":1,"field":"overviewTimeZone","modifiedAt":200,
         "originDeviceID":"old-mac","value":{"overviewTimeZone":{"_0":"Asia/Shanghai"}}}
        """.utf8)
        let decoded = try JSONDecoder().decode(PortableSettingEnvelope.self, from: legacy)
        var settings = makeSettings()
        XCTAssertTrue(settings.applyPortableValue(decoded.value, for: decoded.field))
        XCTAssertEqual(settings.anchorTimeZone.identifier, "Asia/Shanghai")

        let exported = envelope(
            field: .overviewTimeZone, date: newDate,
            value: settings.portableValue(for: .overviewTimeZone))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(exported)) as? [String: Any])
        XCTAssertEqual(object["field"] as? String, "overviewTimeZone")
        let value = try XCTUnwrap(object["value"] as? [String: [String: String]])
        XCTAssertEqual(value, ["overviewTimeZone": ["_0": "Asia/Shanghai"]])
    }

    func testSyncActivityMessageUsesExplicitZone() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        let status = PreferenceSyncStatus.synced(newDate)
        let expected = L10n.format(
            "Last sync activity %@. iCloud may take a few minutes to update other devices.",
            newDate.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: shanghai)))
        XCTAssertEqual(status.message(timeZone: shanghai), expected)
        XCTAssertNotEqual(status.message(timeZone: shanghai), status.message(timeZone: honolulu))
    }

    func testLunarFieldsRoundTripAsIndependentCloudEnvelopes() throws {
        let cloud = InMemoryPreferenceCloudStore()
        let service = entitledService(cloud: cloud)
        let lunar = envelope(
            field: .showsLunarCalendar,
            date: oldDate,
            value: .showsLunarCalendar(true)
        )
        let allDayPolicy = envelope(
            field: .allDayEventDatePolicy,
            date: newDate,
            value: .allDayEventDatePolicy(.overviewTimeZone)
        )
        service.configure(
            localEnvelopeProvider: {
                [
                    .showsLunarCalendar: lunar,
                    .allDayEventDatePolicy: allDayPolicy,
                ]
            },
            importHandler: { _, _ in }
        )

        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        service.completeOnboarding(enable: true)

        XCTAssertEqual(try storedEnvelope(in: cloud, field: .showsLunarCalendar), lunar)
        XCTAssertEqual(
            try storedEnvelope(in: cloud, field: .allDayEventDatePolicy),
            allDayPolicy
        )
    }

    /// The calendar personalization preferences travel with the other calendar display
    /// settings, so each one needs its own envelope and its own place in the settings
    /// round trip — a field that encodes but never applies would sync silently nowhere.
    func testCalendarPersonalizationFieldsRoundTripThroughSettingsAndCloud() throws {
        let fields: [(PortableSettingField, PortableSettingValue)] = [
            (.calendarShowsDateDistance, .calendarShowsDateDistance(false)),
            (.calendarShowsMonthStats, .calendarShowsMonthStats(false)),
            (.calendarWorkdayScheme, .calendarWorkdayScheme(.weekdaysOnly)),
        ]

        var settings = makeSettings()

        for (field, value) in fields {
            XCTAssertTrue(settings.applyPortableValue(value, for: field), "\(field) never applied")
            XCTAssertEqual(settings.portableValue(for: field), value)
        }
        XCTAssertFalse(settings.calendarShowsDateDistance)
        XCTAssertFalse(settings.calendarShowsMonthStats)
        XCTAssertEqual(settings.calendarWorkdayScheme, .weekdaysOnly)

        let cloud = InMemoryPreferenceCloudStore()
        let service = entitledService(cloud: cloud)
        let envelopes = Dictionary(uniqueKeysWithValues: fields.map { field, value in
            (field, envelope(field: field, date: newDate, value: value))
        })
        service.configure(localEnvelopeProvider: { envelopes }, importHandler: { _, _ in })
        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        service.completeOnboarding(enable: true)

        for (field, _) in fields {
            XCTAssertEqual(try storedEnvelope(in: cloud, field: field), envelopes[field])
        }
    }

    func testMismatchedCalendarPersonalizationEnvelopesAreRejected() {
        let mismatched = envelope(
            field: .calendarShowsDateDistance,
            date: newDate,
            value: .calendarShowsMonthStats(false)
        )
        XCTAssertFalse(mismatched.isCompatible)

        var settings = makeSettings()
        XCTAssertFalse(
            settings.applyPortableValue(
                .calendarWorkdayScheme(.weekdaysOnly), for: .calendarShowsMonthStats
            )
        )
        XCTAssertTrue(settings.calendarShowsMonthStats)
    }

    func testDisablementPreservesCloudDataAndStopsFurtherUploads() throws {
        let cloud = InMemoryPreferenceCloudStore()
        let service = entitledService(cloud: cloud)
        let original = envelope(field: .overviewTimeZone, date: oldDate, value: .overviewTimeZone("Asia/Tokyo"))
        service.configure(localEnvelopeProvider: { [.overviewTimeZone: original] }, importHandler: { _, _ in })
        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        service.completeOnboarding(enable: true)

        service.setEnabled(false)
        service.publishLocalChanges([
            envelope(field: .overviewTimeZone, date: newDate, value: .overviewTimeZone("Europe/London"))
        ])

        XCTAssertEqual(service.status, .disabled)
        XCTAssertEqual(try storedEnvelope(in: cloud, field: .overviewTimeZone), original)
    }

    func testRetryFailureAndCloudNotificationsSurfaceRetryAndAccountDecisions() {
        let cloud = InMemoryPreferenceCloudStore()
        let notificationCenter = NotificationCenter()
        let service = entitledService(cloud: cloud, notificationCenter: notificationCenter)
        let local = envelope(field: .overviewTimeZone, date: oldDate, value: .overviewTimeZone("Asia/Tokyo"))
        service.configure(localEnvelopeProvider: { [.overviewTimeZone: local] }, importHandler: { _, _ in })
        service.start(enabled: false, onboardingCompleted: false, storedIdentityToken: nil)
        service.completeOnboarding(enable: true)

        cloud.synchronizeResult = false
        service.retry()
        XCTAssertEqual(
            service.status,
            .failed("iCloud could not synchronize. Verify the app entitlement and iCloud account, then retry.")
        )

        notificationCenter.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud.notificationObject,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreQuotaViolationChange
            ]
        )
        XCTAssertEqual(
            service.status,
            .failed("iCloud preference storage is over quota. Local settings are unchanged.")
        )

        notificationCenter.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud.notificationObject,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreAccountChange
            ]
        )
        XCTAssertEqual(service.status, .needsSourceDecision(.accountChanged))
    }

    func testAppModelImportsOnlyCloudFieldsNewerThanLocalModificationDate() throws {
        let cases: [(name: String, cloudDate: Date, expectedOverview: String)] = [
            ("newer cloud field", newDate, "Europe/London"),
            ("stale cloud field", oldDate, "Asia/Tokyo")
        ]

        for testCase in cases {
            let suite = "MenuCueTests.PreferenceSyncServiceTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }

            let settingsStore = SettingsStore(defaults: defaults)
            var localSettings = settingsStore.load()
            localSettings.anchorTimeZoneID = "Asia/Tokyo"
            localSettings.notificationSettings.isGloballyEnabled = false
            localSettings.preferenceSyncEnabled = true
            localSettings.preferenceSyncOnboardingCompleted = true
            localSettings.iCloudIdentityTokenData = token
            localSettings.portableModificationDates[.overviewTimeZone] = oldDate
            settingsStore.save(localSettings)

            let cloud = InMemoryPreferenceCloudStore()
            let remote = envelope(
                field: .overviewTimeZone,
                date: testCase.cloudDate,
                value: .overviewTimeZone("Europe/London")
            )
            cloud.setData(try JSONEncoder().encode(remote), forKey: cloudKey(for: .overviewTimeZone))
            let sync = entitledService(cloud: cloud)
            _ = NSApplication.shared
            let model = AppModel(
                settingsStore: settingsStore,
                calendarService: CalendarService(),
                appearanceService: AppearanceService(),
                preferenceSyncService: sync
            )

            XCTAssertEqual(model.settings.anchorTimeZoneID, testCase.expectedOverview, testCase.name)
        }
    }

    private func entitledService(
        cloud: InMemoryPreferenceCloudStore,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> PreferenceSyncService {
        PreferenceSyncService(
            store: cloud,
            notificationCenter: notificationCenter,
            isEntitled: true,
            identityTokenDataProvider: { self.token }
        )
    }

    private func makeSettings() -> AppSettings {
        AppSettings(
            statusBarSwitchIntervalSeconds: 5,
            appearanceMode: .system,
            appliesSystemAppearance: false,
            anchorTimeZoneID: "UTC",
            calendarWeekStartDay: .monday,
            calendarSelectionMode: .all,
            selectedCalendarIDs: [],
            pinnedQuickActions: []
        )
    }

    private func envelope(
        field: PortableSettingField,
        date: Date,
        value: PortableSettingValue
    ) -> PortableSettingEnvelope {
        PortableSettingEnvelope(
            field: field,
            modifiedAt: date,
            originDeviceID: "test-device",
            value: value
        )
    }

    private func cloudKey(for field: PortableSettingField) -> String {
        "menucue.preferences.v1.\(field.rawValue)"
    }

    private func storedEnvelope(
        in cloud: InMemoryPreferenceCloudStore,
        field: PortableSettingField
    ) throws -> PortableSettingEnvelope {
        let data = try XCTUnwrap(cloud.data(forKey: cloudKey(for: field)))
        return try JSONDecoder().decode(PortableSettingEnvelope.self, from: data)
    }

    private func assertSynced(
        _ status: PreferenceSyncStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .synced = status else {
            XCTFail("Expected the local and cloud preferences to reconcile, got \(status)", file: file, line: line)
            return
        }
    }
}
