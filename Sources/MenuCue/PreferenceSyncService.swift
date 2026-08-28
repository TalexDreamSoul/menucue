import Combine
import Foundation
import Security

enum PortableSettingField: String, CaseIterable, Codable, Hashable {
    case menuBarFormat
    case clockEntries
    case statusBarSwitchInterval
    case overviewTimeZone
    case calendarWeekStartDay
    case showsLunarCalendar
    case allDayEventDatePolicy
    case calendarShowsDateDistance
    case calendarShowsMonthStats
    case calendarWorkdayScheme
    case appearanceMode
}

enum PortableSettingValue: Codable, Equatable {
    case menuBarFormat(MenuBarFormatSettings)
    case clockEntries([ClockEntry])
    case statusBarSwitchInterval(TimeInterval)
    case overviewTimeZone(String)
    case calendarWeekStartDay(WeekStartDay)
    case showsLunarCalendar(Bool)
    case allDayEventDatePolicy(AllDayEventDatePolicy)
    case calendarShowsDateDistance(Bool)
    case calendarShowsMonthStats(Bool)
    case calendarWorkdayScheme(WorkdayScheme)
    case appearanceMode(AppearanceMode)
}

struct PortableSettingEnvelope: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let field: PortableSettingField
    let modifiedAt: Date
    let originDeviceID: String
    let value: PortableSettingValue

    init(
        field: PortableSettingField,
        modifiedAt: Date,
        originDeviceID: String,
        value: PortableSettingValue
    ) {
        self.schemaVersion = Self.schemaVersion
        self.field = field
        self.modifiedAt = modifiedAt
        self.originDeviceID = originDeviceID
        self.value = value
    }

    var isCompatible: Bool {
        guard schemaVersion == Self.schemaVersion else { return false }
        switch (field, value) {
        case (.menuBarFormat, .menuBarFormat),
             (.clockEntries, .clockEntries),
             (.statusBarSwitchInterval, .statusBarSwitchInterval),
             (.overviewTimeZone, .overviewTimeZone),
             (.calendarWeekStartDay, .calendarWeekStartDay),
             (.showsLunarCalendar, .showsLunarCalendar),
             (.allDayEventDatePolicy, .allDayEventDatePolicy),
             (.calendarShowsDateDistance, .calendarShowsDateDistance),
             (.calendarShowsMonthStats, .calendarShowsMonthStats),
             (.calendarWorkdayScheme, .calendarWorkdayScheme),
             (.appearanceMode, .appearanceMode):
            return true
        default:
            return false
        }
    }
}

enum PreferenceSyncDecisionReason: Equatable {
    case initialMerge
    case accountChanged
}

enum PreferenceSyncStatus: Equatable {
    case unavailable
    case signedOut
    case disabled
    case needsOnboarding
    case needsSourceDecision(PreferenceSyncDecisionReason)
    case syncing
    case synced(Date)
    case failed(String)

    var title: String {
        switch self {
        case .unavailable: return L10n.string("Unavailable in this build")
        case .signedOut: return L10n.string("Sign in to iCloud")
        case .disabled: return L10n.string("Off")
        case .needsOnboarding: return L10n.string("Set up iCloud Sync")
        case .needsSourceDecision(.initialMerge): return L10n.string("Choose initial settings")
        case .needsSourceDecision(.accountChanged): return L10n.string("iCloud account changed")
        case .syncing: return L10n.string("Syncing...")
        case .synced: return L10n.string("Sync active")
        case .failed: return L10n.string("Needs attention")
        }
    }

    /// True when sync needs nothing from the user right now. `.disabled` counts as
    /// healthy: opting out is a valid end state, not a problem to flag.
    var isHealthy: Bool {
        switch self {
        case .disabled, .syncing, .synced:
            return true
        case .unavailable, .signedOut, .needsOnboarding, .needsSourceDecision, .failed:
            return false
        }
    }

    var message: String {
        switch self {
        case .unavailable:
            return L10n.string(
                "This build does not contain the iCloud key-value entitlement. Local settings remain available."
            )
        case .signedOut:
            return L10n.string(
                "Sign in to iCloud in System Settings, then retry. Local changes remain on this Mac."
            )
        case .disabled:
            return L10n.string(
                "Settings are stored only on this Mac. Existing iCloud values are not erased."
            )
        case .needsOnboarding:
            return L10n.string(
                "Sync portable clock, time-zone, week, and appearance preferences across your Macs."
            )
        case .needsSourceDecision(.initialMerge):
            return L10n.string(
                "Both this Mac and iCloud contain settings. Choose which source should win for the first merge."
            )
        case .needsSourceDecision(.accountChanged):
            return L10n.string(
                "Choose whether to use settings from the current iCloud account or upload this Mac's settings."
            )
        case .syncing:
            return L10n.string("Checking iCloud for newer preference values.")
        case let .synced(date):
            return L10n.format(
                "Last sync activity %@. iCloud may take a few minutes to update other devices.",
                date.formatted(date: .abbreviated, time: .shortened)
            )
        case let .failed(message):
            return L10n.format("%@", message)
        }
    }
}

protocol PreferenceCloudStoring: AnyObject {
    var notificationObject: AnyObject { get }
    func data(forKey key: String) -> Data?
    func setData(_ data: Data, forKey key: String)
    func synchronize() -> Bool
}

final class SystemPreferenceCloudStore: PreferenceCloudStoring {
    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    var notificationObject: AnyObject { store }

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func setData(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    func synchronize() -> Bool {
        store.synchronize()
    }
}

final class InMemoryPreferenceCloudStore: PreferenceCloudStoring {
    private var values: [String: Data] = [:]
    private let identity = NSObject()
    var synchronizeResult = true

    var notificationObject: AnyObject { identity }

    func data(forKey key: String) -> Data? {
        values[key]
    }

    func setData(_ data: Data, forKey key: String) {
        values[key] = data
    }

    func synchronize() -> Bool {
        synchronizeResult
    }
}

final class PreferenceSyncService: ObservableObject {
    typealias LocalEnvelopeProvider = () -> [PortableSettingField: PortableSettingEnvelope]
    typealias ImportHandler = ([PortableSettingEnvelope], Bool) -> Void

    @Published private(set) var status: PreferenceSyncStatus

    let isEntitled: Bool
    private let store: PreferenceCloudStoring
    private let notificationCenter: NotificationCenter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var observers: [NSObjectProtocol] = []
    private var localEnvelopeProvider: LocalEnvelopeProvider?
    private var importHandler: ImportHandler?
    private var isEnabled = false
    private var storedIdentityToken: Data?
    private let identityTokenDataProvider: () -> Data?

    init(
        store: PreferenceCloudStoring = SystemPreferenceCloudStore(),
        notificationCenter: NotificationCenter = .default,
        isEntitled: Bool? = nil,
        identityTokenDataProvider: @escaping () -> Data? = PreferenceSyncService.currentIdentityTokenData
    ) {
        let resolvedEntitlement = isEntitled ?? Self.hasICloudKeyValueEntitlement()
        self.store = store
        self.notificationCenter = notificationCenter
        self.isEntitled = resolvedEntitlement
        self.status = resolvedEntitlement ? .disabled : .unavailable
        self.identityTokenDataProvider = identityTokenDataProvider
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }

    func configure(
        localEnvelopeProvider: @escaping LocalEnvelopeProvider,
        importHandler: @escaping ImportHandler
    ) {
        self.localEnvelopeProvider = localEnvelopeProvider
        self.importHandler = importHandler
    }

    func start(
        enabled: Bool,
        onboardingCompleted: Bool,
        storedIdentityToken: Data?
    ) {
        guard isEntitled else {
            status = .unavailable
            return
        }
        registerObserversIfNeeded()
        self.isEnabled = enabled
        self.storedIdentityToken = storedIdentityToken

        guard onboardingCompleted else {
            status = .needsOnboarding
            return
        }
        guard enabled else {
            status = .disabled
            return
        }
        guard let currentToken = identityTokenDataProvider() else {
            status = .signedOut
            return
        }
        if let storedIdentityToken, storedIdentityToken != currentToken {
            status = .needsSourceDecision(.accountChanged)
            return
        }
        reconcileFromCloud()
    }

    func completeOnboarding(enable: Bool) {
        guard isEntitled else { return }
        isEnabled = enable
        guard enable else {
            status = .disabled
            return
        }
        guard let currentIdentityToken = identityTokenDataProvider() else {
            status = .signedOut
            return
        }
        storedIdentityToken = currentIdentityToken

        let cloud = readCloudEnvelopes()
        if cloud.isEmpty {
            uploadLocalSettings()
        } else {
            status = .needsSourceDecision(.initialMerge)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEntitled else { return }
        isEnabled = enabled
        if enabled {
            guard let currentIdentityToken = identityTokenDataProvider() else {
                status = .signedOut
                return
            }
            let hadEstablishedBaseline = storedIdentityToken != nil
            storedIdentityToken = currentIdentityToken
            if !hadEstablishedBaseline, !readCloudEnvelopes().isEmpty {
                status = .needsSourceDecision(.initialMerge)
            } else {
                reconcileFromCloud()
            }
        } else {
            status = .disabled
        }
    }

    func chooseCloudSettings() {
        guard isEnabled else { return }
        let envelopes = Array(readCloudEnvelopes().values)
        if envelopes.isEmpty {
            uploadLocalSettings()
        } else {
            importHandler?(envelopes, true)
            status = .synced(Date())
        }
        storedIdentityToken = identityTokenDataProvider()
    }

    func chooseLocalSettings() {
        guard isEnabled else { return }
        uploadLocalSettings()
        storedIdentityToken = identityTokenDataProvider()
    }

    func publishLocalChanges(_ envelopes: [PortableSettingEnvelope]) {
        guard isEnabled, isEntitled else { return }
        guard !isWaitingForSourceDecision else { return }
        for envelope in envelopes where envelope.isCompatible {
            write(envelope)
        }
        if !envelopes.isEmpty {
            status = .synced(Date())
        }
    }

    func retry() {
        guard isEnabled, isEntitled else { return }
        guard let currentIdentityToken = identityTokenDataProvider() else {
            status = .signedOut
            return
        }
        storedIdentityToken = currentIdentityToken
        reconcileFromCloud()
    }

    var currentIdentityTokenData: Data? {
        identityTokenDataProvider()
    }

    private var isWaitingForSourceDecision: Bool {
        if case .needsSourceDecision = status { return true }
        return false
    }

    private func registerObserversIfNeeded() {
        guard observers.isEmpty else { return }
        observers.append(notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store.notificationObject,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudChange(notification)
        })
        observers.append(notificationCenter.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleIdentityChange()
        })
    }

    private func reconcileFromCloud() {
        guard !isWaitingForSourceDecision else { return }
        status = .syncing
        guard store.synchronize() else {
            status = .failed(
                L10n.string(
                    "iCloud could not synchronize. Verify the app entitlement and iCloud account, then retry."
                )
            )
            return
        }

        let cloud = Array(readCloudEnvelopes().values)
        if cloud.isEmpty {
            uploadLocalSettings()
        } else {
            importHandler?(cloud, false)
            status = .synced(Date())
        }
    }

    private func uploadLocalSettings() {
        guard let localEnvelopeProvider else { return }
        for envelope in localEnvelopeProvider().values where envelope.isCompatible {
            write(envelope)
        }
        status = .synced(Date())
    }

    private func handleCloudChange(_ notification: Notification) {
        guard isEnabled else { return }
        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            status = .failed(
                L10n.string("iCloud preference storage is over quota. Local settings are unchanged.")
            )
        case NSUbiquitousKeyValueStoreAccountChange:
            status = .needsSourceDecision(.accountChanged)
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange,
             nil:
            guard !isWaitingForSourceDecision else { return }
            importHandler?(Array(readCloudEnvelopes().values), false)
            status = .synced(Date())
        default:
            status = .failed(
                L10n.string("iCloud reported an unknown preference synchronization state.")
            )
        }
    }

    private func handleIdentityChange() {
        guard isEnabled else { return }
        guard let currentToken = identityTokenDataProvider() else {
            status = .signedOut
            return
        }
        if let storedIdentityToken, storedIdentityToken == currentToken {
            retry()
        } else {
            status = .needsSourceDecision(.accountChanged)
        }
    }

    private func readCloudEnvelopes() -> [PortableSettingField: PortableSettingEnvelope] {
        var result: [PortableSettingField: PortableSettingEnvelope] = [:]
        for field in PortableSettingField.allCases {
            guard let data = store.data(forKey: cloudKey(for: field)),
                  let envelope = try? decoder.decode(PortableSettingEnvelope.self, from: data),
                  envelope.field == field,
                  envelope.isCompatible
            else {
                continue
            }
            result[field] = envelope
        }
        return result
    }

    private func write(_ envelope: PortableSettingEnvelope) {
        guard let data = try? encoder.encode(envelope) else { return }
        store.setData(data, forKey: cloudKey(for: envelope.field))
    }

    private func cloudKey(for field: PortableSettingField) -> String {
        "menucue.preferences.v1.\(field.rawValue)"
    }

    private static func hasICloudKeyValueEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.ubiquity-kvstore-identifier" as CFString,
                nil
              )
        else {
            return false
        }
        return value is String
    }

    private static func currentIdentityTokenData() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: false
        )
    }
}

extension AppSettings {
    func portableValue(for field: PortableSettingField) -> PortableSettingValue {
        switch field {
        case .menuBarFormat: return .menuBarFormat(menuBarFormat)
        case .clockEntries: return .clockEntries(clockEntries)
        case .statusBarSwitchInterval:
            return .statusBarSwitchInterval(statusBarSwitchIntervalSeconds)
        case .overviewTimeZone: return .overviewTimeZone(overviewTimeZoneID)
        case .calendarWeekStartDay: return .calendarWeekStartDay(calendarWeekStartDay)
        case .showsLunarCalendar: return .showsLunarCalendar(showsLunarCalendar)
        case .allDayEventDatePolicy: return .allDayEventDatePolicy(allDayEventDatePolicy)
        case .calendarShowsDateDistance:
            return .calendarShowsDateDistance(calendarShowsDateDistance)
        case .calendarShowsMonthStats:
            return .calendarShowsMonthStats(calendarShowsMonthStats)
        case .calendarWorkdayScheme: return .calendarWorkdayScheme(calendarWorkdayScheme)
        case .appearanceMode: return .appearanceMode(appearanceMode)
        }
    }

    @discardableResult
    mutating func applyPortableValue(
        _ value: PortableSettingValue,
        for field: PortableSettingField
    ) -> Bool {
        switch (field, value) {
        case let (.menuBarFormat, .menuBarFormat(format)):
            guard MenuBarClockRenderer.validation(for: format) == .valid else { return false }
            menuBarFormat = format
        case let (.clockEntries, .clockEntries(entries)):
            replaceClockEntries(entries)
        case let (.statusBarSwitchInterval, .statusBarSwitchInterval(interval)):
            statusBarSwitchIntervalSeconds = min(30, max(2, interval))
        case let (.overviewTimeZone, .overviewTimeZone(identifier)):
            guard TimeZone(identifier: identifier) != nil else { return false }
            overviewTimeZoneID = identifier
        case let (.calendarWeekStartDay, .calendarWeekStartDay(day)):
            calendarWeekStartDay = day
        case let (.showsLunarCalendar, .showsLunarCalendar(isEnabled)):
            showsLunarCalendar = isEnabled
        case let (.allDayEventDatePolicy, .allDayEventDatePolicy(policy)):
            allDayEventDatePolicy = policy
        case let (.calendarShowsDateDistance, .calendarShowsDateDistance(isEnabled)):
            calendarShowsDateDistance = isEnabled
        case let (.calendarShowsMonthStats, .calendarShowsMonthStats(isEnabled)):
            calendarShowsMonthStats = isEnabled
        case let (.calendarWorkdayScheme, .calendarWorkdayScheme(scheme)):
            calendarWorkdayScheme = scheme
        case let (.appearanceMode, .appearanceMode(mode)):
            appearanceMode = mode
        default:
            return false
        }
        return true
    }
}
