import AppKit
import Foundation

/// Owns the appearance the app renders, and — when the user asks for it — macOS's own
/// Light/Dark setting.
///
/// The system side is **edge triggered**: it is written at the moment the resolved
/// appearance flips (07:00/19:00 in the reference time zone, or a change to the
/// appearance above this row). Between those edges the system appearance belongs to
/// whoever else set it — macOS's own Auto schedule, Control Center, the Dark Mode quick
/// action — and this service deliberately does not take it back.
///
/// Correcting drift was tried and removed. Because the target comes from a schedule
/// rather than from what the user wants right now, every external change looked like a
/// fault to repair: a manual switch survived until the next audit tick, and macOS's own
/// sunrise switch was undone eight seconds after it happened, so the two schedules
/// fought over the same setting at every sunrise and sunset.
final class AppearanceService {
    private var lastAppliedSystemDarkMode: Bool?
    private var hasAppliedAppAppearance = false
    private var lastAppliedAppearanceName: NSAppearance.Name?

    func apply(settings: AppSettings, date: Date = Date()) {
        let targetDarkMode = Self.targetDarkMode(settings: settings, date: date)
        applyAppAppearance(settings: settings, targetDarkMode: targetDarkMode)

        guard settings.appliesSystemAppearance, let targetDarkMode else {
            // Forget what was written: re-enabling the switch has to re-assert the
            // schedule even when it resolves to the appearance already in force.
            lastAppliedSystemDarkMode = nil
            return
        }

        guard lastAppliedSystemDarkMode != targetDarkMode else { return }
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
