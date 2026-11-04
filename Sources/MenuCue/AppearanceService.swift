import AppKit
import Combine
import Foundation

/// Owns the appearance the app renders, and — when the user asks for it — macOS's own
/// Light/Dark setting.
///
/// While the system sync is on, this service is the *sole owner* of that setting. macOS's
/// own Auto schedule is turned off the moment ownership is taken (and restored when it is
/// given back), because two schedules fighting over one switch was the failure mode the
/// first drift-correction attempt died of. With macOS's schedule out of the picture, any
/// mismatch between the resolved target and the system's actual state is either a manual
/// Control Center switch or macOS drifting, and both are corrected after a grace period
/// short enough to feel instant at the next schedule edge yet long enough that a user
/// actively toggling Dark Mode is not fought mid-gesture: the write is simply re-sent once
/// the value settles off-target.
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

    /// How long the system may disagree with the schedule's target before the correction
    /// writes it back. Manual switches are respected as *edits*, not fights: a user toggle
    /// that happens to land off-target is still reverted (that is what ownership means),
    /// but only after this delay, so a user mid-conversation with Control Center is not
    /// wrestling the app.
    static let driftGraceInterval: TimeInterval = 5

    private let writeSystemAppearance: (Bool) -> Result<Void, AppleScriptRunner.Failure>
    private let writeAutoSchedule: (Bool) -> Result<Void, AppleScriptRunner.Failure>
    private let readAutoSchedule: () -> Bool
    private let readCurrentSystemDarkMode: () -> Bool
    private let ownsSystemSchedule: Bool
    private var lastAppliedSystemDarkMode: Bool?
    private var hasAppliedAppAppearance = false
    private var lastAppliedAppearanceName: NSAppearance.Name?

    /// The value the macOS auto schedule had when ownership was taken, so it can be put
    /// back exactly once ownership is released. `nil` means no takeover is in force.
    private var restoredAutoScheduleOnRelease: Bool?
    private var driftSince: Date?

    init(
        writeSystemAppearance: @escaping (Bool) -> Result<Void, AppleScriptRunner.Failure> =
            AppearanceService.applySystemDarkMode,
        writeAutoSchedule: @escaping (Bool) -> Result<Void, AppleScriptRunner.Failure> =
            AppearanceService.setAutoScheduleEnabled,
        readAutoSchedule: @escaping () -> Bool = AppearanceService.autoScheduleEnabled,
        readCurrentSystemDarkMode: @escaping () -> Bool = AppearanceService.currentSystemDarkMode,
        ownsSystemSchedule: Bool = false
    ) {
        self.writeSystemAppearance = writeSystemAppearance
        self.writeAutoSchedule = writeAutoSchedule
        self.readAutoSchedule = readAutoSchedule
        self.readCurrentSystemDarkMode = readCurrentSystemDarkMode
        self.ownsSystemSchedule = ownsSystemSchedule
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
            releaseOwnershipIfNeeded()
            return
        }

        guard ownsSystemSchedule else {
            guard lastAppliedSystemDarkMode != targetDarkMode else { return }
            performWrite(targetDarkMode)
            lastAppliedSystemDarkMode = targetDarkMode
            driftSince = nil
            return
        }
        guard takeOwnershipIfNeeded() else { return }
        guard lastAppliedSystemDarkMode != targetDarkMode else {
            correctDriftIfDue(target: targetDarkMode, at: date)
            return
        }
        performWrite(targetDarkMode)
        // Recorded even when the write failed: a refusal must not be re-sent on the next
        // tick, which would hammer System Events with the same request once a second.
        // `retrySystemAppearance` is the path that forgets it deliberately.
        lastAppliedSystemDarkMode = targetDarkMode
        driftSince = nil
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
        driftSince = nil
        apply(settings: settings, date: date)
    }

    func invalidateSchedule() {
        lastAppliedSystemDarkMode = nil
        driftSince = nil
        hasAppliedAppAppearance = false
    }

    /// Gives the macOS auto schedule back before the app quits, so the takeover does not
    /// outlive the app that made it.
    func stop() {
        releaseOwnershipIfNeeded()
    }

    private func takeOwnershipIfNeeded() -> Bool {
        guard ownsSystemSchedule else { return true }
        guard restoredAutoScheduleOnRelease == nil else { return true }
        let previous = readAutoSchedule()
        if previous {
            switch writeAutoSchedule(false) {
            case .success:
                restoredAutoScheduleOnRelease = true
            case let .failure(failure):
                recordSystemWriteFailure(failure)
                return false
            }
        } else {
            restoredAutoScheduleOnRelease = false
        }
        return true
    }

    private func releaseOwnershipIfNeeded() {
        guard let previous = restoredAutoScheduleOnRelease else { return }
        restoredAutoScheduleOnRelease = nil
        driftSince = nil
        guard previous else { return }
        if case let .failure(failure) = writeAutoSchedule(true) {
            recordSystemWriteFailure(failure)
        }
    }

    /// The per-tick drift audit. While ownership is in force the system setting must match
    /// the schedule's target; a mismatch that survives the grace interval is written back.
    private func correctDriftIfDue(target: Bool, at date: Date) {
        guard currentSystemDarkMode != target else {
            driftSince = nil
            return
        }
        driftSince = driftSince ?? date
        guard let driftSince, date.timeIntervalSince(driftSince) >= Self.driftGraceInterval else {
            return
        }
        performWrite(target)
        self.driftSince = nil
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
            let hour = settings.anchorCalendar.component(.hour, from: date)
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

    /// The macOS auto Light/Dark schedule, as the global preference domain stores it.
    /// Absent means off: Macs that never enabled Auto have no key to read.
    static func autoScheduleEnabled() -> Bool {
        let raw = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?[
                "AppleInterfaceStyleSwitchesAutomatically"
            ]
        if let number = raw as? NSNumber { return number.boolValue }
        return (raw as? String) == "1"
    }

    /// `UserDefaults.set` writes this app's own domain, not the global one the window
    /// server reads, so the whole global domain is rewritten through the persistent-domain
    /// API. It lands immediately (verified with `defaults read` on macOS 26); posting
    /// `AppleInterfaceThemeChangedNotification` is unnecessary.
    static func setAutoScheduleEnabled(_ enabled: Bool) -> Result<Void, AppleScriptRunner.Failure> {
        let defaults = UserDefaults.standard
        var domain = defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        domain["AppleInterfaceStyleSwitchesAutomatically"] = enabled
        defaults.setPersistentDomain(domain, forName: UserDefaults.globalDomain)
        return .success(())
    }

    /// The system's Light/Dark setting, read from the global preferences domain.
    ///
    /// The window server writes `AppleInterfaceStyle` there and removes it for light, which
    /// is exactly what `System Events` reads back — without the Apple Event, and without a
    /// third "unknown" answer for callers to paper over.
    var currentSystemDarkMode: Bool {
        readCurrentSystemDarkMode()
    }

    static func currentSystemDarkMode() -> Bool {
        let style = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        return style == "Dark"
    }
}
