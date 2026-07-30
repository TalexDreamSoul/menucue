import Combine
import Foundation

final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var authorizationState: CalendarAuthorizationState
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var events: [CalendarEventInfo] = []
    @Published var errorMessage: String?
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published var launchAtLoginErrorMessage: String?
    let quickActionService: QuickActionService
    let preferenceSyncService: PreferenceSyncService
    /// One instance for the whole app. The popover, the Dashboard and the background
    /// backfill all read the same history; three services would mean three concurrent
    /// `pmset` runs over the same 24 MB log.
    let powerDiagnosticsService = PowerDiagnosticsService()
    /// Shared for the same reason: the popover, the Dashboard and the background
    /// sampler all contribute to and read one history.
    let processEnergyService = ProcessEnergyService()
    let notificationConfigurationService: NotificationConfigurationService
    let notificationRuntimeStore: NotificationRuntimeStore
    let notificationDeliveryDispatcher: NotificationDeliveryDispatcher
    let alertMonitoringService: AlertMonitoringService
    let notificationRuntimeErrorMessage: String?

    private let settingsStore: SettingsStore
    private let calendarService: CalendarService
    private let appearanceService: AppearanceService
    private let launchAtLoginService: LaunchAtLoginManaging

    init(
        settingsStore: SettingsStore,
        calendarService: CalendarService,
        appearanceService: AppearanceService,
        launchAtLoginService: LaunchAtLoginManaging = LaunchAtLoginService(),
        quickActionService: QuickActionService? = nil,
        preferenceSyncService: PreferenceSyncService? = nil,
        notificationRuntimeStore: NotificationRuntimeStore? = nil,
        notificationRuntimeErrorMessage: String? = nil,
        notificationSecretStore: any NotificationSecretStoring = InMemoryNotificationSecretStore(),
        notificationHTTPTransport: any NotificationHTTPTransport = URLSessionNotificationHTTPTransport()
    ) {
        let runtimeStore = notificationRuntimeStore ?? Self.temporaryNotificationRuntimeStore()
        let configurationService = NotificationConfigurationService(
            secrets: notificationSecretStore,
            transport: notificationHTTPTransport
        )
        let deliveryDispatcher = NotificationDeliveryDispatcher(
            store: runtimeStore,
            configuration: configurationService
        )
        self.notificationRuntimeStore = runtimeStore
        self.notificationConfigurationService = configurationService
        self.notificationDeliveryDispatcher = deliveryDispatcher
        self.notificationRuntimeErrorMessage = notificationRuntimeErrorMessage
        self.alertMonitoringService = AlertMonitoringService(
            store: runtimeStore,
            providers: AlertMonitoringService.liveProviders()
        )
        self.settingsStore = settingsStore
        self.calendarService = calendarService
        self.appearanceService = appearanceService
        self.launchAtLoginService = launchAtLoginService
        self.quickActionService = quickActionService
            ?? QuickActionService(appearanceService: appearanceService)
        self.preferenceSyncService = preferenceSyncService ?? PreferenceSyncService()
        self.launchAtLoginState = launchAtLoginService.state
        self.settings = settingsStore.load()
        self.authorizationState = calendarService.authorizationState
        appearanceService.apply(settings: settings)
        refreshCalendarData()

        self.preferenceSyncService.configure(
            localEnvelopeProvider: { [weak self] in
                self?.portableEnvelopes() ?? [:]
            },
            importHandler: { [weak self] envelopes, force in
                self?.importPortableEnvelopes(envelopes, force: force)
            }
        )
        self.preferenceSyncService.start(
            enabled: settings.preferenceSyncEnabled,
            onboardingCompleted: settings.preferenceSyncOnboardingCompleted,
            storedIdentityToken: settings.iCloudIdentityTokenData
        )
        configureNotificationServices(settings.notificationSettings)
    }

    func updateSettings(_ update: (inout AppSettings) -> Void) {
        let previousSettings = settings
        var nextSettings = previousSettings
        update(&nextSettings)
        guard nextSettings != previousSettings else { return }

        let changedPortableFields = PortableSettingField.allCases.filter { field in
            previousSettings.portableValue(for: field) != nextSettings.portableValue(for: field)
        }
        if !changedPortableFields.isEmpty {
            let modificationDate = Date()
            for field in changedPortableFields {
                nextSettings.portableModificationDates[field] = modificationDate
            }
        }

        applySettings(nextSettings)
        guard nextSettings.preferenceSyncEnabled else { return }
        preferenceSyncService.publishLocalChanges(
            Array(portableEnvelopes(for: changedPortableFields, settings: nextSettings).values)
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            launchAtLoginErrorMessage = nil
        } catch {
            launchAtLoginErrorMessage = L10n.format(
                "Could not update Launch at Login: %@",
                error.localizedDescription
            )
        }
        refreshLaunchAtLoginState()
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginState = launchAtLoginService.state
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func addTimeZone(identifier: String) {
        updateSettings { settings in
            settings.addClock(identifier: identifier)
        }
    }

    func addSystemClock() {
        updateSettings { settings in
            settings.addSystemClock()
        }
    }

    func removeClock(id: String) {
        updateSettings { settings in
            settings.removeClock(id: id)
        }
    }

    func moveClock(id: String, by offset: Int) {
        updateSettings { settings in
            settings.moveClock(id: id, by: offset)
        }
    }

    func moveClocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        updateSettings { settings in
            settings.moveClocks(fromOffsets: source, toOffset: destination)
        }
    }

    func movePopoverTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        updateSettings { settings in
            settings.movePopoverTabs(fromOffsets: source, toOffset: destination)
        }
    }

    func updateClockLabel(id: String, label: String?) {
        updateSettings { settings in
            settings.updateClockLabel(id: id, label: label)
        }
    }

    @discardableResult
    func updateMenuBarFormat(_ format: MenuBarFormatSettings) -> Bool {
        guard MenuBarClockRenderer.validation(for: format) == .valid else { return false }
        updateSettings { settings in
            settings.menuBarFormat = format
        }
        return true
    }

    func resetMenuBarFormat() {
        updateMenuBarFormat(.compatibilityDefault)
    }

    func completePreferenceSyncOnboarding(enable: Bool) {
        var nextSettings = settings
        nextSettings.preferenceSyncOnboardingCompleted = true
        nextSettings.preferenceSyncEnabled = enable
        if enable {
            nextSettings.iCloudIdentityTokenData = preferenceSyncService.currentIdentityTokenData
        }
        applySettings(nextSettings)
        preferenceSyncService.completeOnboarding(enable: enable)
    }

    func setPreferenceSyncEnabled(_ enabled: Bool) {
        var nextSettings = settings
        nextSettings.preferenceSyncOnboardingCompleted = true
        nextSettings.preferenceSyncEnabled = enabled
        if enabled {
            nextSettings.iCloudIdentityTokenData = preferenceSyncService.currentIdentityTokenData
        }
        applySettings(nextSettings)
        preferenceSyncService.setEnabled(enabled)
    }

    func chooseCloudPreferenceSettings() {
        preferenceSyncService.chooseCloudSettings()
        persistCurrentICloudIdentityToken()
    }

    func chooseLocalPreferenceSettings() {
        var nextSettings = settings
        let modificationDate = Date()
        for field in PortableSettingField.allCases {
            nextSettings.portableModificationDates[field] = modificationDate
        }
        nextSettings.iCloudIdentityTokenData = preferenceSyncService.currentIdentityTokenData
        applySettings(nextSettings)
        preferenceSyncService.chooseLocalSettings()
    }

    func retryPreferenceSync() {
        persistCurrentICloudIdentityToken()
        preferenceSyncService.retry()
    }

    /// Called every time the user looks at power, so history keeps accruing after the
    /// window closes.
    ///
    /// Starting the timer here rather than only at launch is the point: persisting the
    /// preference alone meant the very session in which someone first opened the pane
    /// was the one session that did not backfill, and the promised "what woke my Mac
    /// overnight" only began working the *next* time the app started.
    /// `startBackgroundMonitoring` is idempotent, so calling this on every appearance
    /// is free.
    func enablePowerMonitoring() {
        if !settings.powerMonitoringEnabled {
            updateSettings { $0.powerMonitoringEnabled = true }
        }
        powerDiagnosticsService.startBackgroundMonitoring()
        // Same reasoning, same pairing as `StatusBarController.configurePowerMonitoring`.
        // Starting only one of the two here would leave "what kept running" blank for
        // the whole first session while "what woke my Mac" filled in.
        processEnergyService.startBackgroundSampling()
    }

    func updateNotificationSettings(_ update: (inout NotificationSettings) -> Void) {
        updateSettings { settings in
            update(&settings.notificationSettings)
        }
    }

    func saveNotificationSecret(_ value: String, for key: NotificationSecretKey) throws {
        try notificationConfigurationService.saveSecret(value, for: key)
        configureNotificationServices(settings.notificationSettings)
    }

    func removeNotificationSecret(_ key: NotificationSecretKey) throws {
        try notificationConfigurationService.removeSecret(key)
        configureNotificationServices(settings.notificationSettings)
    }

    func testNotificationChannel(_ kind: NotificationChannelKind) async {
        await notificationConfigurationService.testChannel(
            kind,
            settings: settings.notificationSettings,
            systemDeviceName: Host.current().localizedName
        )
    }

    func updateMetricsSampling(_ update: (inout MetricsSamplingSettings) -> Void) {
        updateSettings { settings in
            var sampling = settings.metricsSampling
            update(&sampling)
            settings.metricsSampling = sampling.normalized
        }
    }

    func addPinnedQuickAction(_ reference: QuickActionReference) {
        guard settings.pinnedQuickActions.count < 7 else { return }
        guard !settings.pinnedQuickActions.contains(reference) else { return }
        guard quickActionService.isAvailable(reference) else { return }
        updateSettings { settings in
            settings.pinnedQuickActions.append(reference)
        }
    }

    func removePinnedQuickAction(_ reference: QuickActionReference) {
        updateSettings { settings in
            settings.pinnedQuickActions.removeAll { $0 == reference }
        }
    }

    func movePinnedQuickAction(at index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.pinnedQuickActions.indices.contains(index) else { return }
        guard settings.pinnedQuickActions.indices.contains(destination) else { return }
        updateSettings { settings in
            settings.pinnedQuickActions.swapAt(index, destination)
        }
    }

    func quickEventDraft(startDate: Date = Date()) -> QuickEventDraft {
        QuickEventDraft(startDate: startDate, calendarID: calendarService.defaultNewEventCalendarID)
    }

    func createEvent(from draft: QuickEventDraft) {
        do {
            try calendarService.createEvent(from: draft)
            errorMessage = nil
            refreshCalendarData()
        } catch {
            errorMessage = L10n.format("Could not save the event: %@", error.localizedDescription)
        }
    }


    func refreshCalendarData() {
        authorizationState = calendarService.authorizationState
        guard authorizationState.canReadEvents else {
            calendars = []
            events = []
            return
        }

        calendars = calendarService.calendars()
        refreshEventsIfPossible()
    }

    func requestCalendarAccess() {
        calendarService.requestAccess { [weak self] state, error in
            DispatchQueue.main.async {
                self?.authorizationState = state
                self?.errorMessage = error.map {
                    L10n.format("Could not update Calendar access: %@", $0.localizedDescription)
                }
                self?.refreshCalendarData()
            }
        }
    }

    func refreshTimeDrivenState() {
        appearanceService.apply(settings: settings)
    }

    private func applySettings(_ nextSettings: AppSettings) {
        settings = nextSettings
        settingsStore.save(nextSettings)
        appearanceService.apply(settings: nextSettings)
        configureNotificationServices(nextSettings.notificationSettings)
        refreshEventsIfPossible()
    }

    private func configureNotificationServices(_ notificationSettings: NotificationSettings) {
        let monitor = alertMonitoringService
        let dispatcher = notificationDeliveryDispatcher
        Task { @MainActor [weak self, weak monitor, weak dispatcher] in
            guard let self, let monitor, let dispatcher else { return }
            await dispatcher.update(settings: notificationSettings)
            await monitor.setDeviceName(
                notificationSettings.resolvedDeviceName(systemName: Host.current().localizedName)
            )
            await monitor.setDeliveryHandler { [weak dispatcher] in
                await dispatcher?.kick()
            }
            try? await monitor.updateRules(notificationSettings.rules)
            await monitor.start()
            self.configureDarkWakeBridge(
                enabled: notificationSettings.rules.contains {
                    $0.isEnabled && $0.metricID == "event.darkWake"
                },
                monitor: monitor
            )
        }
    }

    private func configureDarkWakeBridge(
        enabled: Bool,
        monitor: AlertMonitoringService
    ) {
        if enabled {
            powerDiagnosticsService.setDarkWakeMonitoring(
                historyHandler: { [weak monitor] events in
                    Task { await monitor?.processDarkWakeEvents(events) }
                },
                onSleep: { [weak monitor] in
                    Task { await monitor?.handleSystemSleep() }
                },
                onWake: { [weak monitor] in
                    Task { await monitor?.handleSystemWake() }
                }
            )
        } else {
            powerDiagnosticsService.setDarkWakeMonitoring(historyHandler: nil)
        }
    }

    private static func temporaryNotificationRuntimeStore() -> NotificationRuntimeStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuCue-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("notification-runtime-v1.json")
        return try! NotificationRuntimeStore(fileURL: url)
    }

    private func portableEnvelopes(
        for fields: [PortableSettingField] = PortableSettingField.allCases,
        settings: AppSettings? = nil
    ) -> [PortableSettingField: PortableSettingEnvelope] {
        let source = settings ?? self.settings
        return Dictionary(uniqueKeysWithValues: fields.map { field in
            let envelope = PortableSettingEnvelope(
                field: field,
                modifiedAt: source.portableModificationDates[field] ?? .distantPast,
                originDeviceID: source.syncDeviceID,
                value: source.portableValue(for: field)
            )
            return (field, envelope)
        })
    }

    private func importPortableEnvelopes(
        _ envelopes: [PortableSettingEnvelope],
        force: Bool
    ) {
        var nextSettings = settings
        var didApplyValue = false

        for envelope in envelopes where envelope.isCompatible {
            if !force,
               let localDate = nextSettings.portableModificationDates[envelope.field],
               envelope.modifiedAt <= localDate
            {
                continue
            }
            guard nextSettings.applyPortableValue(envelope.value, for: envelope.field) else {
                continue
            }
            nextSettings.portableModificationDates[envelope.field] = envelope.modifiedAt
            didApplyValue = true
        }

        guard didApplyValue else { return }
        applySettings(nextSettings)
    }

    private func persistCurrentICloudIdentityToken() {
        guard settings.iCloudIdentityTokenData != preferenceSyncService.currentIdentityTokenData else {
            return
        }
        var nextSettings = settings
        nextSettings.iCloudIdentityTokenData = preferenceSyncService.currentIdentityTokenData
        applySettings(nextSettings)
    }

    private func refreshEventsIfPossible() {
        guard authorizationState.canReadEvents else {
            events = []
            return
        }
        events = calendarService.upcomingEvents(settings: settings)
    }
}
