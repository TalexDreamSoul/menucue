import AppKit
import Combine
import EventKit
import Foundation

final class CalendarRefreshController {
    static let observedNames: [Notification.Name] = [
        .EKEventStoreChanged,
        .NSCalendarDayChanged,
        .NSSystemTimeZoneDidChange,
        .NSSystemClockDidChange,
        NSLocale.currentLocaleDidChangeNotification,
        // Coming back from System Settings is how a permission change reaches us; EventKit
        // does not announce one.
        NSApplication.didBecomeActiveNotification,
    ]

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let delay: TimeInterval
    private let action: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var workItem: DispatchWorkItem?

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        delay: TimeInterval = 0.2,
        action: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.delay = delay
        self.action = action
        start()
    }

    deinit {
        workItem?.cancel()
        for (center, token) in observers {
            center.removeObserver(token)
        }
    }

    private func start() {
        for name in Self.observedNames {
            let token = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.schedule()
            }
            observers.append((notificationCenter, token))
        }

        let token = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.schedule()
        }
        observers.append((workspaceNotificationCenter, token))
    }

    private func schedule() {
        workItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.action()
        }
        self.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var authorizationState: CalendarAuthorizationState
    /// Set when a request came back without moving the state, meaning macOS declined to
    /// show its prompt and only System Settings can change the answer now.
    @Published private(set) var calendarPromptSuppressed = false
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var events: [CalendarEventInfo] = []
    @Published var errorMessage: String?
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published var launchAtLoginErrorMessage: String?
    let quickActionService: QuickActionService
    let trackpadGestureService: TrackpadGestureService
    let preferenceSyncService: PreferenceSyncService
    /// One instance for the whole app. The popover, the Dashboard and the background
    /// backfill all read the same history; three services would mean three concurrent
    /// `pmset` runs over the same 24 MB log.
    let powerDiagnosticsService = PowerDiagnosticsService()
    /// Shared for the same reason: the popover, the Dashboard and the background
    /// sampler all contribute to and read one history.
    let processEnergyService = ProcessEnergyService()
    /// Explicit diagnostics only: scans run after a user request and are never persisted.
    let processHealthService = ProcessHealthService()
    let notificationConfigurationService: NotificationConfigurationService
    let notificationRuntimeStore: NotificationRuntimeStore
    let notificationDeliveryDispatcher: NotificationDeliveryDispatcher
    let alertMonitoringService: AlertMonitoringService
    let notificationRuntimeErrorMessage: String?

    private let settingsStore: SettingsStore
    private let calendarService: CalendarService
    private let appearanceService: AppearanceService
    private let launchAtLoginService: LaunchAtLoginManaging
    private var visibleCalendarMonthDate = Date()
    private var calendarRefreshController: CalendarRefreshController?

    init(
        settingsStore: SettingsStore,
        calendarService: CalendarService,
        appearanceService: AppearanceService,
        launchAtLoginService: LaunchAtLoginManaging = LaunchAtLoginService(),
        quickActionService: QuickActionService? = nil,
        trackpadGestureService: TrackpadGestureService? = nil,
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
        let resolvedQuickActionService = quickActionService
            ?? QuickActionService(appearanceService: appearanceService)
        self.quickActionService = resolvedQuickActionService
        self.trackpadGestureService = trackpadGestureService
            ?? TrackpadGestureService(quickActionService: resolvedQuickActionService)
        self.preferenceSyncService = preferenceSyncService ?? PreferenceSyncService()
        self.launchAtLoginState = launchAtLoginService.state
        self.settings = settingsStore.load()
        self.authorizationState = calendarService.authorizationState
        appearanceService.apply(settings: settings)
        self.trackpadGestureService.apply(settings: settings.trackpadGestureSettings)
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
        calendarRefreshController = CalendarRefreshController { [weak self] in
            self?.refreshCalendarData()
        }
        configureNotificationServices(settings.notificationSettings)
    }

    deinit {
        trackpadGestureService.stop()
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

    func updateTrackpadGestureSettings(_ settings: TrackpadGestureSettings) {
        updateSettings { $0.trackpadGestureSettings = settings.normalized }
    }

    func updateTrackpadGestureSettings(_ update: (inout TrackpadGestureSettings) -> Void) {
        updateSettings { settings in
            var trackpadSettings = settings.trackpadGestureSettings
            update(&trackpadSettings)
            settings.trackpadGestureSettings = trackpadSettings.normalized
        }
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

    /// The one way this preference changes, in either direction.
    ///
    /// Applying it here rather than only at launch is the point: persisting the
    /// preference alone meant the very session in which someone turned this on was the
    /// one session that did not backfill, and the promised "what woke my Mac overnight"
    /// only began working the *next* time the app started. Turning it off has to be
    /// just as immediate — the setting is the only thing standing between an idle Mac
    /// and a recurring `pmset -g log` plus `top`.
    ///
    /// Both samplers move together in both directions. Starting one alone leaves "what
    /// kept running" blank while "what woke my Mac" fills in; stopping one alone leaves
    /// the more expensive of the two running with the switch reading off.
    func setPowerMonitoring(enabled: Bool) {
        if settings.powerMonitoringEnabled != enabled {
            updateSettings { $0.powerMonitoringEnabled = enabled }
        }
        if enabled {
            powerDiagnosticsService.startBackgroundMonitoring()
            processEnergyService.startBackgroundSampling()
        } else {
            powerDiagnosticsService.stopBackgroundMonitoring()
            processEnergyService.stopBackgroundSampling()
        }
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


    func refreshCalendarData(visibleMonthDate: Date? = nil) {
        if let visibleMonthDate {
            self.visibleCalendarMonthDate = visibleMonthDate
        }
        authorizationState = calendarService.authorizationState
        // Once macOS has an answer on record, the suppressed-prompt hint is stale.
        if authorizationState != .notDetermined {
            calendarPromptSuppressed = false
        }
        guard authorizationState.canReadEvents else {
            calendars = []
            events = []
            return
        }

        calendars = calendarService.calendars()
        refreshEventsIfPossible()
    }

    func setVisibleCalendarMonth(_ date: Date) {
        let timeZone = settings.overviewTimeZone
        let previous = CivilDateKey(date: visibleCalendarMonthDate, timeZone: timeZone)
        let next = CivilDateKey(date: date, timeZone: timeZone)
        guard previous.year != next.year || previous.month != next.month else { return }
        visibleCalendarMonthDate = date
        refreshEventsIfPossible()
    }

    func requestCalendarAccess() {
        calendarService.requestAccess { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = state
                // A request that returns still-undecided means the prompt never reached the
                // user. Remember it, or the button we show them is one that does nothing.
                self.calendarPromptSuppressed = state == .notDetermined
                self.errorMessage = error.map {
                    L10n.format("Could not update Calendar access: %@", $0.localizedDescription)
                }
                self.refreshCalendarData()
            }
        }
    }

    var calendarPermissionGuidance: CalendarPermissionGuidance? {
        CalendarPermissionAdvisor.guidance(
            for: authorizationState,
            promptSuppressed: calendarPromptSuppressed
        )
    }

    func performCalendarPermissionAction(_ action: CalendarPermissionAction) {
        switch action {
        case .request:
            requestCalendarAccess()
        case .openSettings:
            NSWorkspace.shared.open(CalendarPermissionLinks.systemCalendarSettings)
        }
    }

    func refreshTimeDrivenState() {
        appearanceService.apply(settings: settings)
    }

    private func applySettings(_ nextSettings: AppSettings) {
        let previousTrackpadSettings = settings.trackpadGestureSettings
        settings = nextSettings
        settingsStore.save(nextSettings)
        appearanceService.apply(settings: nextSettings)
        if previousTrackpadSettings != nextSettings.trackpadGestureSettings {
            trackpadGestureService.apply(settings: nextSettings.trackpadGestureSettings)
        }
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
        events = calendarService.events(
            settings: settings,
            visibleMonthDate: visibleCalendarMonthDate
        )
    }
}
