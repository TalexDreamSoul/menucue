import Foundation

enum CalendarPermissionLinks {
    /// Deep link to Privacy & Security → Calendars, where the user toggles MenuCue on.
    static let systemCalendarSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )!
}

/// What the user can actually do about the current authorization state.
enum CalendarPermissionAction: Equatable {
    /// macOS can still raise its own prompt, so asking is the shortest path.
    case request
    /// The decision now lives in System Settings; asking again would do nothing visible.
    case openSettings
}

struct CalendarPermissionGuidance: Equatable {
    let message: String
    let action: CalendarPermissionAction
}

/// Resolves authorization state into one instruction.
///
/// The state alone is not enough. macOS raises its permission prompt once per app per
/// service; after that prompt has been consumed, `requestAccess` returns immediately with
/// no error while the status stays `notDetermined` — identical, from the outside, to never
/// having asked. `promptSuppressed` carries the one bit that tells those apart, and without
/// it the UI can only offer a button that silently does nothing.
enum CalendarPermissionAdvisor {
    static func guidance(
        for state: CalendarAuthorizationState,
        promptSuppressed: Bool
    ) -> CalendarPermissionGuidance? {
        switch state {
        case .fullAccess:
            return nil

        case .notDetermined:
            guard promptSuppressed else {
                return CalendarPermissionGuidance(
                    message: L10n.string(
                        "Grant Calendar access to show iCloud and local Calendar events."
                    ),
                    action: .request
                )
            }
            return CalendarPermissionGuidance(
                message: L10n.string(
                    "macOS did not show the permission dialog. Open System Settings and turn on MenuCue under Privacy & Security → Calendars."
                ),
                action: .openSettings
            )

        case .denied:
            return CalendarPermissionGuidance(
                message: L10n.string(
                    "Calendar access is turned off. Open System Settings and turn on MenuCue under Privacy & Security → Calendars."
                ),
                action: .openSettings
            )

        case .restricted:
            return CalendarPermissionGuidance(
                message: L10n.string(
                    "Calendar access is restricted by a profile or parental controls on this Mac."
                ),
                action: .openSettings
            )

        // Write-only can still be escalated by a fresh request, so keep asking.
        case .writeOnly, .unknown:
            return CalendarPermissionGuidance(
                message: state.title,
                action: .request
            )
        }
    }
}

extension CalendarPermissionAction {
    var buttonTitle: String {
        switch self {
        case .request: return L10n.string("Grant Calendar Access")
        case .openSettings: return L10n.string("Open System Settings")
        }
    }
}
