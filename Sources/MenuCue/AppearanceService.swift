import AppKit
import Combine
import Foundation

/// Owns the appearance the app renders, and — when the user asks for it — macOS's own
/// Light/Dark setting.
///
/// The system side is **edge triggered**: it is written at the moment the resolved
/// appearance flips (07:00/19:00 in the reference time zone, or a change to the appearance
/// above this row). Between those edges the system appearance belongs to whoever else set
/// it — macOS's own Auto schedule, Control Center, the Dark Mode quick action — and this
/// service deliberately does not take it back.
///
/// Correcting drift was tried and removed. Because the target comes from a schedule rather
/// than from what the user wants right now, every external change looked like a fault to
/// repair: a manual switch survived until the next audit tick, and macOS's own sunrise
/// switch was undone eight seconds after it happened, so the two schedules fought over the
/// same setting at every sunrise and sunset.
///
/// Reading stays local. The system's setting is a global preference — the same one the
/// window server and AppKit read — so asking System Events for it was an out-of-process
/// Apple Event that needed the very Automation grant the write does, and a revoked grant
/// answered "not dark" instead of "I cannot tell".
final class AppearanceService: ObservableObject {
    /// The last system-appearance write macOS refused, if any.
    ///
    /// The write is the one thing here that can fail quietly: `tell application "System
    /// Events"` needs the Automation grant, and macOS reports a refusal as an AppleScript
    /// error nobody was reading. Keeping it lets the row that owns the switch say so and
    /// hand over the permission, instead of leaving a switch that looks on and does nothing.
    @Published private(set) var systemWriteFailure: AppleScriptRunner.Failure?

    private let writeSystemAppearance: (Bool) -> Result<Void, AppleScriptRunner.Failure>
    private var lastAppliedSystemDarkMode: Bool?
    private var hasAppliedAppAppearance = false
    private var lastAppliedAppearanceName: NSAppearance.Name?

    init(
        writeSystemAppearance: @escaping (Bool) -> Result<Void, AppleScriptRunner.Failure> =
            AppearanceService.applySystemDarkMode
    ) {
        self.writeSystemAppearance = writeSystemAppearance
    }

    func apply(settings: AppSettings, date: Date = Date()) {
        let targetDarkMode = Self.targetDarkMode(settings: settings, date: date)
        applyAppAppearance(settings: settings, targetDarkMode: targetDarkMode)

        guard settings.appliesSystemAppearance, let targetDarkMode else {
            // Forget what was written: re-enabling the switch has to re-assert the schedule
            // even when it resolves to the appearance already in force. The refusal goes
            // with it — nothing is being applied, so nothing is failing.
            lastAppliedSystemDarkMode = nil
            recordSystemWriteFailure(nil)
            return
        }

        guard lastAppliedSystemDarkMode != targetDarkMode else { return }
        performWrite(targetDarkMode)
        // Recorded even when the write failed: a refusal must not be re-sent on the next
        // tick, which would hammer System Events with the same request once a second.
        // `retrySystemAppearance` is the path that forgets it deliberately.
        lastAppliedSystemDarkMode = targetDarkMode
    }

    /// Writes the system appearance on the user's behalf — the Dark Mode quick action, not
    /// the schedule.
    ///
    /// Deliberately leaves `lastAppliedSystemDarkMode` alone: that memory is what the
    /// *schedule* last wrote, so the next switch point still asserts itself over a manual
    /// toggle rather than being skipped as already applied.
    func setSystemDarkMode(_ enabled: Bool) {
        performWrite(enabled)
    }

    /// Writes the schedule again after a refusal, so a grant added in System Settings takes
    /// effect now instead of at the next switch point. The banner's retry, a launch, and
    /// flipping the switch off and back on all end up here.
    func retrySystemAppearance(settings: AppSettings, date: Date = Date()) {
        lastAppliedSystemDarkMode = nil
        apply(settings: settings, date: date)
    }

    private func performWrite(_ targetDarkMode: Bool) {
        switch writeSystemAppearance(targetDarkMode) {
        case .success:
            recordSystemWriteFailure(nil)
        case let .failure(failure):
            recordSystemWriteFailure(failure)
        }
    }

    /// Only a real change is published: `@Published` announces every assignment, and the
    /// caller's per-second refresh would otherwise redraw the settings pane once a second
    /// for a value that never moved.
    private func recordSystemWriteFailure(_ failure: AppleScriptRunner.Failure?) {
        guard systemWriteFailure != failure else { return }
        systemWriteFailure = failure
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

    static func applySystemDarkMode(_ enabled: Bool) -> Result<Void, AppleScriptRunner.Failure> {
        AppleScriptRunner.run(
            """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to \(enabled ? "true" : "false")
                end tell
            end tell
            """
        )
    }

    /// The system's Light/Dark setting, read from the global preferences domain.
    ///
    /// The window server writes `AppleInterfaceStyle` there and removes it for light, which
    /// is exactly what `System Events` reads back — without the Apple Event, and without a
    /// third "unknown" answer for callers to paper over.
    var currentSystemDarkMode: Bool {
        let style = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        return style == "Dark"
    }
}
