import Foundation

final class SettingsStore {
    private enum Key {
        static let menuBarFormat = "menuBarFormat.v1"
        static let clockEntries = "clockEntries.v1"
        static let statusBarSwitchIntervalSeconds = "statusBarSwitchIntervalSeconds"
        static let appearanceMode = "appearanceMode"
        static let appearanceTimeZoneID = "appearanceTimeZoneID"
        static let appliesSystemAppearance = "appliesSystemAppearance"
        static let overviewTimeZoneID = "overviewTimeZoneID"
        static let calendarWeekStartDay = "calendarWeekStartDay"
        static let calendarSelectionMode = "calendarSelectionMode"
        static let selectedCalendarIDs = "selectedCalendarIDs"
        static let pinnedQuickActions = "pinnedQuickActions"
        static let popoverTabOrder = "popoverTabOrder.v1"
        static let metricsSampling = "metricsSampling.v1"
        static let powerMonitoringEnabled = "powerMonitoringEnabled.v1"
        static let notificationSettings = "notificationSettings.v1"
        static let preferenceSyncEnabled = "preferenceSyncEnabled"
        static let preferenceSyncOnboardingCompleted = "preferenceSyncOnboardingCompleted"
        static let portableModificationDates = "portableModificationDates.v1"
        static let iCloudIdentityTokenData = "iCloudIdentityTokenData"
        static let syncDeviceID = "syncDeviceID"

        static let legacyDisplayTimeZoneMode = "displayTimeZoneMode"
        static let legacyCustomDisplayTimeZoneID = "customDisplayTimeZoneID"
        static let legacyShowsSystemTimeZone = "showsSystemTimeZone"
        static let legacySelectedTimeZoneIDs = "selectedTimeZoneIDs"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        let systemTimeZoneID = TimeZone.autoupdatingCurrent.identifier
        let legacyMode = TimeZoneMode(
            rawValue: defaults.string(forKey: Key.legacyDisplayTimeZoneMode) ?? ""
        ) ?? .system
        let legacyCustomTimeZoneID =
            defaults.string(forKey: Key.legacyCustomDisplayTimeZoneID) ?? systemTimeZoneID
        let legacySelectedTimeZoneIDs =
            defaults.stringArray(forKey: Key.legacySelectedTimeZoneIDs)
            ?? defaultSelectedTimeZoneIDs(
                legacyMode: legacyMode,
                legacyCustomTimeZoneID: legacyCustomTimeZoneID,
                systemTimeZoneID: systemTimeZoneID
            )

        return AppSettings(
            menuBarFormat: loadMenuBarFormat(),
            clockEntries: loadClockEntries(
                legacySelectedTimeZoneIDs: legacySelectedTimeZoneIDs,
                systemTimeZoneID: systemTimeZoneID
            ),
            statusBarSwitchIntervalSeconds: loadStatusBarSwitchIntervalSeconds(defaultValue: 5),
            appearanceMode: AppearanceMode(
                rawValue: defaults.string(forKey: Key.appearanceMode) ?? ""
            ) ?? .system,
            appearanceTimeZoneID: defaults.string(forKey: Key.appearanceTimeZoneID)
                ?? systemTimeZoneID,
            appliesSystemAppearance: defaults.bool(forKey: Key.appliesSystemAppearance),
            overviewTimeZoneID: defaults.string(forKey: Key.overviewTimeZoneID)
                ?? systemTimeZoneID,
            calendarWeekStartDay: loadCalendarWeekStartDay(defaultValue: .monday),
            calendarSelectionMode: CalendarSelectionMode(
                rawValue: defaults.string(forKey: Key.calendarSelectionMode) ?? ""
            ) ?? .all,
            selectedCalendarIDs: Set(defaults.stringArray(forKey: Key.selectedCalendarIDs) ?? []),
            pinnedQuickActions: loadPinnedQuickActions(),
            popoverTabOrder: loadPopoverTabOrder(),
            metricsSampling: loadMetricsSampling(),
            powerMonitoringEnabled: defaults.bool(forKey: Key.powerMonitoringEnabled),
            notificationSettings: loadNotificationSettings(),
            preferenceSyncEnabled: defaults.bool(forKey: Key.preferenceSyncEnabled),
            preferenceSyncOnboardingCompleted: defaults.bool(
                forKey: Key.preferenceSyncOnboardingCompleted
            ),
            portableModificationDates: loadPortableModificationDates(),
            iCloudIdentityTokenData: defaults.data(forKey: Key.iCloudIdentityTokenData),
            syncDeviceID: loadSyncDeviceID()
        )
    }

    func save(_ settings: AppSettings) {
        if let data = try? encoder.encode(settings.menuBarFormat) {
            defaults.set(data, forKey: Key.menuBarFormat)
        }
        if let data = try? encoder.encode(settings.clockEntries) {
            defaults.set(data, forKey: Key.clockEntries)
        }
        defaults.set(settings.statusBarSwitchIntervalSeconds, forKey: Key.statusBarSwitchIntervalSeconds)
        defaults.set(settings.appearanceMode.rawValue, forKey: Key.appearanceMode)
        defaults.set(settings.appearanceTimeZoneID, forKey: Key.appearanceTimeZoneID)
        defaults.set(settings.appliesSystemAppearance, forKey: Key.appliesSystemAppearance)
        defaults.set(settings.overviewTimeZoneID, forKey: Key.overviewTimeZoneID)
        defaults.set(settings.calendarWeekStartDay.rawValue, forKey: Key.calendarWeekStartDay)
        defaults.set(settings.calendarSelectionMode.rawValue, forKey: Key.calendarSelectionMode)
        defaults.set(Array(settings.selectedCalendarIDs).sorted(), forKey: Key.selectedCalendarIDs)
        defaults.set(settings.pinnedQuickActions.map(\.storageValue), forKey: Key.pinnedQuickActions)
        defaults.set(settings.popoverTabOrder.map(\.rawValue), forKey: Key.popoverTabOrder)
        defaults.set(settings.powerMonitoringEnabled, forKey: Key.powerMonitoringEnabled)
        if let data = try? encoder.encode(settings.notificationSettings) {
            defaults.set(data, forKey: Key.notificationSettings)
        }
        if let data = try? encoder.encode(settings.metricsSampling) {
            defaults.set(data, forKey: Key.metricsSampling)
        }
        defaults.set(settings.preferenceSyncEnabled, forKey: Key.preferenceSyncEnabled)
        defaults.set(
            settings.preferenceSyncOnboardingCompleted,
            forKey: Key.preferenceSyncOnboardingCompleted
        )
        defaults.set(
            Dictionary(uniqueKeysWithValues: settings.portableModificationDates.map {
                ($0.key.rawValue, $0.value.timeIntervalSinceReferenceDate)
            }),
            forKey: Key.portableModificationDates
        )
        defaults.set(settings.iCloudIdentityTokenData, forKey: Key.iCloudIdentityTokenData)
        defaults.set(settings.syncDeviceID, forKey: Key.syncDeviceID)
    }

    private func loadNotificationSettings() -> NotificationSettings {
        guard let data = defaults.data(forKey: Key.notificationSettings),
              let settings = try? decoder.decode(NotificationSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    private func loadMetricsSampling() -> MetricsSamplingSettings {
        guard let data = defaults.data(forKey: Key.metricsSampling),
              let settings = try? decoder.decode(MetricsSamplingSettings.self, from: data)
        else {
            return .default
        }
        return settings.normalized
    }

    private func loadMenuBarFormat() -> MenuBarFormatSettings {
        guard let data = defaults.data(forKey: Key.menuBarFormat),
              let format = try? decoder.decode(MenuBarFormatSettings.self, from: data),
              MenuBarClockRenderer.validation(for: format) == .valid
        else {
            return .compatibilityDefault
        }
        return format
    }

    private func loadClockEntries(
        legacySelectedTimeZoneIDs: [String],
        systemTimeZoneID: String
    ) -> [ClockEntry] {
        if defaults.object(forKey: Key.clockEntries) != nil {
            guard let data = defaults.data(forKey: Key.clockEntries),
                  let entries = try? decoder.decode([ClockEntry].self, from: data)
            else {
                return [.system()]
            }
            return entries
        }

        var entries: [ClockEntry] = []
        let includesSystem = loadLegacyShowsSystemTimeZone(defaultValue: true)
        if includesSystem {
            entries.append(.system())
        }

        var seen = Set(entries.map(\.id))
        for identifier in legacySelectedTimeZoneIDs {
            guard !(includesSystem && identifier == systemTimeZoneID) else { continue }
            guard seen.insert(identifier).inserted else { continue }
            guard let entry = ClockEntry.custom(identifier: identifier) else { continue }
            entries.append(entry)
        }
        return entries.isEmpty ? [.system()] : entries
    }

    private func loadLegacyShowsSystemTimeZone(defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: Key.legacyShowsSystemTimeZone) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: Key.legacyShowsSystemTimeZone)
    }

    private func loadStatusBarSwitchIntervalSeconds(defaultValue: TimeInterval) -> TimeInterval {
        guard defaults.object(forKey: Key.statusBarSwitchIntervalSeconds) != nil else {
            return defaultValue
        }
        return min(30, max(2, defaults.double(forKey: Key.statusBarSwitchIntervalSeconds)))
    }

    private func loadCalendarWeekStartDay(defaultValue: WeekStartDay) -> WeekStartDay {
        guard defaults.object(forKey: Key.calendarWeekStartDay) != nil else {
            return defaultValue
        }
        return WeekStartDay(rawValue: defaults.integer(forKey: Key.calendarWeekStartDay))
            ?? defaultValue
    }

    private func loadPopoverTabOrder() -> [PopoverTab] {
        guard defaults.object(forKey: Key.popoverTabOrder) != nil else {
            return PopoverTab.allCases
        }
        return PopoverTab.normalizedOrder(
            rawValues: defaults.stringArray(forKey: Key.popoverTabOrder) ?? []
        )
    }

    private func loadPinnedQuickActions() -> [QuickActionReference] {
        guard defaults.object(forKey: Key.pinnedQuickActions) != nil else {
            return BuiltInQuickActionID.defaultPinned
        }

        var seen = Set<QuickActionReference>()
        var references: [QuickActionReference] = []
        for storageValue in defaults.stringArray(forKey: Key.pinnedQuickActions) ?? [] {
            guard let reference = QuickActionReference(storageValue: storageValue) else { continue }
            guard seen.insert(reference).inserted else { continue }
            references.append(reference)
            if references.count == 7 { break }
        }
        return references
    }

    private func loadPortableModificationDates() -> [PortableSettingField: Date] {
        guard let stored = defaults.dictionary(
            forKey: Key.portableModificationDates
        ) as? [String: TimeInterval] else {
            return [:]
        }

        var result: [PortableSettingField: Date] = [:]
        for (rawField, timestamp) in stored {
            guard let field = PortableSettingField(rawValue: rawField),
                  timestamp.isFinite
            else {
                continue
            }
            result[field] = Date(timeIntervalSinceReferenceDate: timestamp)
        }
        return result
    }

    private func loadSyncDeviceID() -> String {
        if let existing = defaults.string(forKey: Key.syncDeviceID), !existing.isEmpty {
            return existing
        }
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: Key.syncDeviceID)
        return identifier
    }

    private func defaultSelectedTimeZoneIDs(
        legacyMode: TimeZoneMode,
        legacyCustomTimeZoneID: String,
        systemTimeZoneID: String
    ) -> [String] {
        guard legacyMode == .custom, legacyCustomTimeZoneID != systemTimeZoneID else {
            return []
        }
        return TimeZone(identifier: legacyCustomTimeZoneID) == nil
            ? [] : [legacyCustomTimeZoneID]
    }
}
