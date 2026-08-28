import Foundation

/// Where an action can be offered. An action registered for one surface is not hidden
/// from the other by accident — it simply was never registered there.
enum ActionSurface: String, CaseIterable, Hashable {
  /// The Quick Actions grid in the popover.
  case panel
  /// Selectable as the action of a trackpad gesture rule.
  case trackpad
}

/// Where an entry came from, which is how the Action Center splits one flat register into
/// lists a user can reason about: what MenuCue ships, what they wrote in Shortcuts, and
/// what only the trackpad can reach.
enum ActionSource: String, CaseIterable, Identifiable, Hashable {
  case builtIn
  case shortcut
  case trackpadNative

  var id: String { rawValue }

  var title: String {
    switch self {
    case .builtIn: return L10n.string("Built-in")
    case .shortcut: return L10n.string("Shortcuts")
    case .trackpadNative: return L10n.string("Trackpad Native")
    }
  }
}

/// Whether an action can run right now, why not, and where the user fixes it. Both action
/// surfaces report availability in this shape, so a failure always carries the same three
/// pieces of information.
struct ActionAvailability: Equatable {
  let isAvailable: Bool
  let reason: String?
  let settingsURL: URL?

  static let available = ActionAvailability(
    isAvailable: true,
    reason: nil,
    settingsURL: nil
  )

  static func unavailable(_ reason: String, settingsURL: URL? = nil) -> ActionAvailability {
    ActionAvailability(
      isAvailable: false,
      reason: reason,
      settingsURL: settingsURL
    )
  }
}

/// What the system has to grant before an action can run. Runtime conditions that are not
/// permissions — a missing Shortcut, an unregistered helper — stay with the service that
/// observes them.
enum ActionRequirement: Equatable {
  case none
  /// The wording differs per action because the user is told what the access is for.
  case accessibility(reason: String)
}

/// How a catalog entry is executed. The catalog decides nothing about execution; it only
/// records which executor owns the entry.
enum ActionRoute: Equatable {
  case quickAction(QuickActionReference)
  case trackpad(TrackpadGestureAction)
  /// Activating whatever window sits under the pointer, which a trackpad rule can also
  /// request as a prelude to its own action.
  case trackpadPointerWindow
}

struct ActionCatalogItem: Identifiable, Equatable {
  let id: String
  let title: String
  let systemImage: String
  let source: ActionSource
  let surfaces: Set<ActionSurface>
  let isDestructive: Bool
  let requirement: ActionRequirement
  let route: ActionRoute

  func isOffered(on surface: ActionSurface) -> Bool { surfaces.contains(surface) }
}

/// A place an action is already spoken for. The Action Center shows these so unpinning an
/// action or repointing a rule is a decision made with its dependents in view.
enum ActionReference: Equatable {
  case pinned
  case gestureRule(name: String)
}

/// The single register of everything the app can do on a user's behalf: the built-in Quick
/// Actions, the Shortcuts discovered at runtime, and the trackpad's own system operations.
/// It holds no state and performs nothing.
enum ActionCatalog {
  /// The built-in Quick Actions, in the order the popover has always shown them.
  static var builtInQuickActions: [ActionCatalogItem] {
    BuiltInQuickActionID.allCases.map { actionID in
      let reference = QuickActionReference.builtIn(actionID)
      return ActionCatalogItem(
        id: reference.storageValue,
        title: actionID.title,
        systemImage: actionID.systemImage,
        source: .builtIn,
        surfaces: [.panel, .trackpad],
        isDestructive: actionID.isDestructive,
        // Their permissions depend on live system state, which QuickActionService owns.
        requirement: .none,
        route: .quickAction(reference)
      )
    }
  }

  static func shortcutActions(_ names: [String]) -> [ActionCatalogItem] {
    names.map { name in
      let reference = QuickActionReference.shortcut(name)
      return ActionCatalogItem(
        id: reference.storageValue,
        title: name,
        systemImage: "command.square.fill",
        source: .shortcut,
        surfaces: [.panel, .trackpad],
        isDestructive: false,
        requirement: .none,
        route: .quickAction(reference)
      )
    }
  }

  /// System operations only a trackpad gesture can reach today. They are registered here
  /// so a future surface can offer them without reaching into the executor's switch.
  static var trackpadNativeActions: [ActionCatalogItem] {
    var items: [ActionCatalogItem] = []

    for control in TrackpadSystemControl.allCases {
      items.append(
        trackpadItem(
          title: control.actionTitle,
          systemImage: control.actionSystemImage,
          action: .system(control)
        )
      )
    }

    for placement in TrackpadWindowAction.allCases {
      items.append(
        trackpadItem(
          title: placement.actionTitle,
          systemImage: "macwindow",
          action: TrackpadGestureAction(kind: .window, windowAction: placement)
        )
      )
    }

    for click in TrackpadMouseAction.allCases {
      items.append(
        trackpadItem(
          title: click.actionTitle,
          systemImage: "cursorarrow.click",
          action: TrackpadGestureAction(kind: .mouse, mouseAction: click)
        )
      )
    }

    for direction in TrackpadDirection.allCases {
      items.append(
        trackpadItem(
          title: L10n.format("Scroll %@", direction.actionTitle),
          systemImage: "arrow.up.and.down",
          action: TrackpadGestureAction(kind: .scroll, scrollDirection: direction)
        )
      )
    }

    // The remaining families carry user-supplied parameters, so the catalog registers the
    // family once rather than every configuration of it.
    items.append(
      trackpadItem(
        title: L10n.string("Keyboard Shortcut"),
        systemImage: "keyboard",
        action: TrackpadGestureAction(kind: .keyboardShortcut)
      )
    )
    items.append(
      trackpadItem(
        title: L10n.string("Open Target"),
        systemImage: "arrow.up.forward.app",
        action: TrackpadGestureAction(kind: .open)
      )
    )
    items.append(
      trackpadItem(
        title: L10n.string("AppleScript"),
        systemImage: "applescript",
        action: TrackpadGestureAction(kind: .appleScript)
      )
    )
    items.append(
      ActionCatalogItem(
        id: pointerWindowItemID,
        title: L10n.string("Activate Window Under Pointer"),
        systemImage: "macwindow.on.rectangle",
        source: .trackpadNative,
        surfaces: [.trackpad],
        isDestructive: false,
        requirement: .none,
        route: .trackpadPointerWindow
      )
    )
    return items
  }

  static func items(surface: ActionSurface, shortcuts: [String] = []) -> [ActionCatalogItem] {
    allItems(shortcuts: shortcuts).filter { $0.isOffered(on: surface) }
  }

  /// Everything registered, regardless of surface. The Action Center is the one view that
  /// shows the whole register, since its job is to say what exists and where it is used.
  static func allItems(shortcuts: [String] = []) -> [ActionCatalogItem] {
    builtInQuickActions + shortcutActions(shortcuts) + trackpadNativeActions
  }

  /// The Quick Action references a surface offers, in catalog order. The popover builds
  /// its grid from this instead of enumerating the built-in identifiers itself.
  static func quickActionReferences(
    surface: ActionSurface,
    shortcuts: [String] = []
  ) -> [QuickActionReference] {
    items(surface: surface, shortcuts: shortcuts).compactMap { item in
      guard case .quickAction(let reference) = item.route else { return nil }
      return reference
    }
  }

  /// What a trackpad gesture action needs granted before it can run.
  static func requirement(forActionKind kind: TrackpadGestureActionKind) -> ActionRequirement {
    switch kind {
    case .keyboardShortcut:
      return .accessibility(reason: L10n.string("Allow Accessibility access to send keyboard shortcuts."))
    case .mouse:
      return .accessibility(reason: L10n.string("Allow Accessibility access to send mouse clicks."))
    case .scroll:
      return .accessibility(reason: L10n.string("Allow Accessibility access to send mouse scrolling."))
    case .window:
      return .accessibility(reason: L10n.string("Allow Accessibility access to place windows."))
    case .systemControl, .quickAction, .open, .appleScript, .none:
      return .none
    }
  }

  static func availability(
    for requirement: ActionRequirement,
    accessibilityStatus: AccessibilityPermissionStatus,
    accessibilitySettingsURL: URL
  ) -> ActionAvailability {
    switch requirement {
    case .none:
      return .available
    case .accessibility(let reason):
      guard accessibilityStatus == .granted else {
        return .unavailable(reason, settingsURL: accessibilitySettingsURL)
      }
      return .available
    }
  }

  /// Where an action is already spoken for: pinned to the popover, or selected by a
  /// gesture rule. Pure, so the Action Center's "used by" column is testable without a
  /// running app.
  static func references(
    of item: ActionCatalogItem,
    pinned: [QuickActionReference],
    rules: [TrackpadGestureRule]
  ) -> [ActionReference] {
    var references: [ActionReference] = []
    if pinned.contains(where: { $0.storageValue == item.id }) {
      references.append(.pinned)
    }
    for rule in rules where rule.uses(item) {
      references.append(.gestureRule(name: rule.settingsDisplayName))
    }
    return references
  }

  /// The catalog entry a configured gesture action points at. A rule stores the action's
  /// own parameters rather than a catalog identifier, so the mapping back lives here,
  /// next to the identifiers it has to agree with.
  static func itemID(for action: TrackpadGestureAction) -> String? {
    switch action.kind {
    case .quickAction:
      return action.quickActionStorageValue.isEmpty ? nil : action.quickActionStorageValue
    case .systemControl:
      return trackpadItemID(family: "systemControl", variant: action.systemControl.rawValue)
    case .window:
      return trackpadItemID(family: "window", variant: action.windowAction.rawValue)
    case .mouse:
      return trackpadItemID(family: "mouse", variant: action.mouseAction.rawValue)
    case .scroll:
      return trackpadItemID(family: "scroll", variant: action.scrollDirection.rawValue)
    // Parameterized families are registered once, so every configuration of one maps
    // onto that single entry.
    case .keyboardShortcut:
      return trackpadItemID(family: "keyboardShortcut", variant: nil)
    case .open:
      return trackpadItemID(family: "open", variant: nil)
    case .appleScript:
      return trackpadItemID(family: "appleScript", variant: nil)
    case .none:
      return nil
    }
  }

  static let pointerWindowItemID = "trackpad:pointerWindow"

  private static func trackpadItem(
    title: String,
    systemImage: String,
    action: TrackpadGestureAction
  ) -> ActionCatalogItem {
    ActionCatalogItem(
      id: itemID(for: action) ?? action.kind.rawValue,
      title: title,
      systemImage: systemImage,
      source: .trackpadNative,
      surfaces: [.trackpad],
      isDestructive: false,
      requirement: requirement(forActionKind: action.kind),
      route: .trackpad(action)
    )
  }

  private static func trackpadItemID(family: String, variant: String?) -> String {
    guard let variant else { return "trackpad:\(family)" }
    return "trackpad:\(family):\(variant)"
  }
}

extension TrackpadGestureRule {
  /// Whether this rule depends on a catalog entry — either as its action, or as the
  /// pointer-window step it can run first.
  func uses(_ item: ActionCatalogItem) -> Bool {
    if item.route == .trackpadPointerWindow {
      return activatesWindowUnderPointer
    }
    return ActionCatalog.itemID(for: action) == item.id
  }
}

// The titles below are the catalog's, and the settings editor reads them from here so a
// renamed action cannot say two different things in two places.

extension TrackpadSystemControl {
  var actionTitle: String {
    switch self {
    case .volumeUp: return L10n.string("Volume Up")
    case .volumeDown: return L10n.string("Volume Down")
    case .toggleMute: return L10n.string("Toggle Mute")
    case .brightnessUp: return L10n.string("Brightness Up")
    case .brightnessDown: return L10n.string("Brightness Down")
    case .continuousVolume: return L10n.string("Continuous Volume")
    case .continuousBrightness: return L10n.string("Continuous Brightness")
    }
  }

  var actionSystemImage: String {
    switch self {
    case .volumeUp, .continuousVolume: return "speaker.wave.3.fill"
    case .volumeDown: return "speaker.wave.1.fill"
    case .toggleMute: return "speaker.slash.fill"
    case .brightnessUp, .continuousBrightness: return "sun.max.fill"
    case .brightnessDown: return "sun.min.fill"
    }
  }
}

extension TrackpadWindowAction {
  var actionTitle: String {
    switch self {
    case .leftHalf: return L10n.string("Left Half")
    case .rightHalf: return L10n.string("Right Half")
    case .topHalf: return L10n.string("Top Half")
    case .bottomHalf: return L10n.string("Bottom Half")
    case .topLeftQuarter: return L10n.string("Top-left Quarter")
    case .topRightQuarter: return L10n.string("Top-right Quarter")
    case .bottomLeftQuarter: return L10n.string("Bottom-left Quarter")
    case .bottomRightQuarter: return L10n.string("Bottom-right Quarter")
    case .maximize: return L10n.string("Maximize")
    case .center: return L10n.string("Center")
    case .restore: return L10n.string("Restore")
    case .nextDisplay: return L10n.string("Move to Next Display")
    }
  }
}

extension TrackpadMouseAction {
  var actionTitle: String {
    switch self {
    case .leftClick: return L10n.string("Left Click")
    case .rightClick: return L10n.string("Right Click")
    case .middleClick: return L10n.string("Middle Click")
    }
  }
}

extension TrackpadDirection {
  var actionTitle: String {
    switch self {
    case .up: return L10n.string("Up")
    case .down: return L10n.string("Down")
    case .left: return L10n.string("Left")
    case .right: return L10n.string("Right")
    }
  }
}
