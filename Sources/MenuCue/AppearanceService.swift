import AppKit
import Foundation

final class AppearanceService {
    private let systemAppearanceAuditInterval: TimeInterval = 15
    private var lastAppliedSystemDarkMode: Bool?
    private var lastSystemAppearanceAuditDate: Date?
    private var hasAppliedAppAppearance = false
    private var lastAppliedAppearanceName: NSAppearance.Name?

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
        let name: NSAppearance.Name?
        switch settings.appearanceMode {
        case .system:
            name = nil
        case .light:
            name = .aqua
        case .dark:
            name = .darkAqua
        case .automaticByTimeZone:
            name = targetDarkMode == true ? .darkAqua : .aqua
        }

        // Assigning NSApp.appearance is never a no-op: AppKit invalidates every window
        // appearance and walks the view tree, so the caller's per-second refresh must not
        // reach it unless the resolved appearance actually changed. `nil` (follow the
        // system) is a real value here, hence the separate first-apply flag.
        guard !hasAppliedAppAppearance || lastAppliedAppearanceName != name else { return }
        hasAppliedAppAppearance = true
        lastAppliedAppearanceName = name
        NSApp.appearance = name.flatMap { NSAppearance(named: $0) }
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
