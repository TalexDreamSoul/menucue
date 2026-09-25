import Foundation

/// Where macOS keeps the per-app Automation grants.
///
/// MenuCue drives System Events for the system appearance (and for any AppleScript action
/// the user writes into a trackpad rule), and macOS gates all of that behind one grant per
/// target application. The pane below is the only place it can be given or taken away, so
/// anything that fails for want of it points here.
enum AutomationPermission {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!
}
