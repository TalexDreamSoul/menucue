import AppKit
import Foundation

final class AppearanceService {
    private let systemAppearanceAuditInterval: TimeInterval = 15
    private var lastAppliedSystemDarkMode: Bool?
    private var lastSystemAppearanceAuditDate: Date?

    func apply(settings: AppSettings, date: Date = Date()) {
        let targetDarkMode = Self.targetDarkMode(settings: settings, date: date)
        applyAppAppearance(settings: settings, targetDarkMode: targetDarkMode)

        guard settings.appliesSystemAppearance, let targetDarkMode else {
            lastAppliedSystemDarkMode = nil
            lastSystemAppearanceAuditDate = nil
            return
        }

        let targetChanged = lastAppliedSystemDarkMode != targetDarkMode
        let systemDrifted = !targetChanged && systemAppearanceDidDrift(from: targetDarkMode, at: date)
        guard targetChanged || systemDrifted else { return }

        setSystemDarkMode(targetDarkMode)
        lastAppliedSystemDarkMode = targetDarkMode
    }

    private func applyAppAppearance(settings: AppSettings, targetDarkMode: Bool?) {
        switch settings.appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .automaticByTimeZone:
            NSApp.appearance = NSAppearance(named: targetDarkMode == true ? .darkAqua : .aqua)
        }
    }

    private static func targetDarkMode(settings: AppSettings, date: Date) -> Bool? {
        switch settings.appearanceMode {
        case .system:
            return nil
        case .light:
            return false
        case .dark:
            return true
        case .automaticByTimeZone:
            let hour = Calendar(identifier: .gregorian).dateComponents(in: settings.appearanceTimeZone, from: date).hour ?? 12
            return !(7..<19).contains(hour)
        }
    }

    func setSystemDarkMode(_ enabled: Bool) {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enabled ? "true" : "false")
            end tell
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    private func systemAppearanceDidDrift(from targetDarkMode: Bool, at date: Date) -> Bool {
        guard shouldAuditSystemAppearance(at: date) else { return false }
        guard let currentSystemDarkMode else { return false }
        return currentSystemDarkMode != targetDarkMode
    }

    private func shouldAuditSystemAppearance(at date: Date) -> Bool {
        guard let lastSystemAppearanceAuditDate else {
            self.lastSystemAppearanceAuditDate = date
            return true
        }

        guard date.timeIntervalSince(lastSystemAppearanceAuditDate) >= systemAppearanceAuditInterval else {
            return false
        }

        self.lastSystemAppearanceAuditDate = date
        return true
    }

    var currentSystemDarkMode: Bool? {
        let script = """
        tell application "System Events"
            tell appearance preferences
                return dark mode
            end tell
        end tell
        """
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return descriptor?.booleanValue
    }
}
