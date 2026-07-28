import Foundation

enum QuickActionKind: Equatable {
  case toggle
  case button
  case mode
}

enum BuiltInQuickActionID: String, CaseIterable, Identifiable {
  case turnOffDisplays
  case lowPowerMode
  case preventLidSleep
  case darkMode
  case lockScreen
  case keepScreenOn
  case screenSaver
  case hideDesktopIcons
  case autoHideDock
  case hideNotch
  case autoHideMenuBar
  case cleanScreen
  case cleanKeyboard
  case emptyTrash

  var id: String { rawValue }

  var title: String {
    switch self {
    case .turnOffDisplays: return "Turn Off Displays"
    case .lowPowerMode: return "Low Power Mode"
    case .preventLidSleep: return "Don't Sleep When Closed"
    case .darkMode: return "Dark Mode"
    case .lockScreen: return "Lock Screen"
    case .keepScreenOn: return "Keep Screen On"
    case .screenSaver: return "Screen Saver"
    case .hideDesktopIcons: return "Hide Desktop"
    case .autoHideDock: return "Auto-hide Dock"
    case .hideNotch: return "Hide Notch"
    case .autoHideMenuBar: return "Auto-hide Menu Bar"
    case .cleanScreen: return "Clean Screen"
    case .cleanKeyboard: return "Clean Keyboard"
    case .emptyTrash: return "Empty Trash"
    }
  }

  var systemImage: String {
    switch self {
    case .turnOffDisplays: return "display"
    case .lowPowerMode: return "bolt.fill"
    case .preventLidSleep: return "cup.and.saucer.fill"
    case .darkMode: return "circle.lefthalf.filled"
    case .lockScreen: return "lock.display"
    case .keepScreenOn: return "sun.max.fill"
    case .screenSaver: return "play.display"
    case .hideDesktopIcons: return "eye.slash"
    case .autoHideDock: return "dock.arrow.down.rectangle"
    case .hideNotch: return "laptopcomputer"
    case .autoHideMenuBar: return "menubar.arrow.up.rectangle"
    case .cleanScreen: return "sparkles.rectangle.stack"
    case .cleanKeyboard: return "keyboard"
    case .emptyTrash: return "trash"
    }
  }

  var kind: QuickActionKind {
    switch self {
    case .lowPowerMode, .preventLidSleep, .darkMode, .keepScreenOn,
      .hideDesktopIcons, .autoHideDock, .hideNotch, .autoHideMenuBar:
      return .toggle
    case .turnOffDisplays, .lockScreen, .screenSaver, .emptyTrash:
      return .button
    case .cleanScreen, .cleanKeyboard:
      return .mode
    }
  }

  var isDestructive: Bool {
    self == .emptyTrash
  }

  static let defaultPinned: [QuickActionReference] = [
    .builtIn(.darkMode),
    .builtIn(.lockScreen),
    .builtIn(.keepScreenOn),
    .builtIn(.screenSaver),
    .builtIn(.hideDesktopIcons),
    .builtIn(.autoHideDock),
    .builtIn(.autoHideMenuBar),
  ]
}

enum QuickActionReference: Hashable, Identifiable {
  case builtIn(BuiltInQuickActionID)
  case shortcut(String)

  private static let builtInPrefix = "builtin:"
  private static let shortcutPrefix = "shortcut:"

  var id: String { storageValue }

  var storageValue: String {
    switch self {
    case .builtIn(let actionID):
      return Self.builtInPrefix + actionID.rawValue
    case .shortcut(let name):
      return Self.shortcutPrefix + name
    }
  }

  var displayTitle: String {
    switch self {
    case .builtIn(let actionID): return actionID.title
    case .shortcut(let name): return name
    }
  }

  init?(storageValue: String) {
    if storageValue.hasPrefix(Self.builtInPrefix) {
      let rawValue = String(storageValue.dropFirst(Self.builtInPrefix.count))
      guard let actionID = BuiltInQuickActionID(rawValue: rawValue) else { return nil }
      self = .builtIn(actionID)
      return
    }

    if storageValue.hasPrefix(Self.shortcutPrefix) {
      let name = String(storageValue.dropFirst(Self.shortcutPrefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      self = .shortcut(name)
      return
    }

    return nil
  }
}

struct QuickActionAvailability: Equatable {
  let isAvailable: Bool
  let reason: String?
  let settingsURL: URL?

  static let available = QuickActionAvailability(
    isAvailable: true,
    reason: nil,
    settingsURL: nil
  )

  static func unavailable(_ reason: String, settingsURL: URL? = nil) -> QuickActionAvailability {
    QuickActionAvailability(
      isAvailable: false,
      reason: reason,
      settingsURL: settingsURL
    )
  }
}

struct QuickActionState: Equatable {
  var availability: QuickActionAvailability
  var isOn: Bool?
  var isRunning: Bool

  static let available = QuickActionState(
    availability: .available,
    isOn: nil,
    isRunning: false
  )
}

struct QuickActionItem: Identifiable, Equatable {
  let reference: QuickActionReference
  let title: String
  let systemImage: String
  let kind: QuickActionKind
  let isDestructive: Bool
  let state: QuickActionState

  var id: String { reference.id }
}
