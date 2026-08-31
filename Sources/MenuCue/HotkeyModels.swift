import Carbon.HIToolbox
import Foundation

/// One global keyboard shortcut and the catalog entry it runs.
///
/// The action is stored as an `ActionCatalogItem.id` rather than as a configured action:
/// a hotkey picks an entry out of the register, and the register is what knows how that
/// entry executes.
struct HotkeyBinding: Codable, Equatable, Identifiable {
  var id: UUID
  /// Empty means the row is titled by the action it runs, which is what most bindings
  /// want; a name is only worth storing when it says something the action does not.
  var name: String
  var shortcut: TrackpadKeyboardShortcut
  var actionItemID: String
  var isEnabled: Bool

  init(
    id: UUID = UUID(),
    name: String = "",
    shortcut: TrackpadKeyboardShortcut = TrackpadKeyboardShortcut(),
    actionItemID: String = "",
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.shortcut = shortcut
    self.actionItemID = actionItemID
    self.isEnabled = isEnabled
  }

  /// A binding written before a field existed still has to decode: one that throws takes
  /// the whole list of shortcuts down with it.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = HotkeyBinding()
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      name: try container.decodeIfPresent(String.self, forKey: .name) ?? fallback.name,
      shortcut: try container.decodeIfPresent(TrackpadKeyboardShortcut.self, forKey: .shortcut)
        ?? fallback.shortcut,
      actionItemID: try container.decodeIfPresent(String.self, forKey: .actionItemID)
        ?? fallback.actionItemID,
      isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
    )
  }

  var normalized: HotkeyBinding {
    var result = self
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    result.actionItemID = actionItemID.trimmingCharacters(in: .whitespacesAndNewlines)
    return result
  }

  /// What the settings list calls this binding: its own name when it has one, otherwise
  /// the action it runs, otherwise the shortcut itself.
  func settingsDisplayName(actionTitle: String?) -> String {
    if !name.isEmpty { return name }
    if let actionTitle, !actionTitle.isEmpty { return actionTitle }
    return shortcut.isUnset ? L10n.string("New Shortcut") : shortcut.displayText
  }
}

/// Why a binding cannot be saved. Every case is something the editor can state before the
/// shortcut is ever registered, so a combination that could not work is refused while it is
/// being written rather than failing silently later.
enum HotkeyBindingValidation: Equatable {
  case valid
  case missingShortcut
  /// A bare key would swallow that key everywhere in macOS, and `fn` is not a modifier
  /// the system hot-key table can be asked for.
  case missingModifier
  case missingAction
  case conflict(name: String)

  var isValid: Bool { self == .valid }

  var message: String? {
    switch self {
    case .valid:
      return nil
    case .missingShortcut:
      return L10n.string("Record a keyboard shortcut for this action.")
    case .missingModifier:
      return L10n.string("Add ⌘, ⌃, or ⌥ so this shortcut cannot capture ordinary typing.")
    case .missingAction:
      return L10n.string("Choose the action this shortcut runs.")
    case .conflict(let name):
      return L10n.format("This shortcut is already used by %@.", name)
    }
  }
}

/// The rules a binding has to satisfy before it is stored, kept apart from the editor so
/// what the Save button allows and what the service will try to register are the same
/// question asked once.
enum HotkeyBindingPolicy {
  /// `fn` and `shift` are deliberately not enough on their own: `fn` has no equivalent in
  /// the system hot-key table, and a shift-only combination captures ordinary typing.
  static let requiredModifiers: Set<TrackpadModifier> = [.command, .control, .option]

  static func validate(
    _ binding: HotkeyBinding,
    against others: [HotkeyBinding],
    actionTitles: [String: String] = [:]
  ) -> HotkeyBindingValidation {
    if binding.shortcut.isUnset { return .missingShortcut }
    guard !binding.shortcut.modifiers.isDisjoint(with: requiredModifiers) else {
      return .missingModifier
    }
    if binding.actionItemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .missingAction
    }
    if let conflicting = others.first(where: {
      $0.id != binding.id && $0.shortcut.claimsSameKey(as: binding.shortcut)
    }) {
      return .conflict(
        name: conflicting.settingsDisplayName(
          actionTitle: actionTitles[conflicting.actionItemID]
        )
      )
    }
    return .valid
  }

  /// The bindings the service should hand to the system: enabled, complete, and with the
  /// later of two duplicates dropped rather than left to fail registration.
  static func registrable(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
    var result: [HotkeyBinding] = []
    for binding in bindings where binding.isEnabled {
      guard validate(binding, against: result).isValid else { continue }
      result.append(binding)
    }
    return result
  }
}

/// Stable, removable-once defaults that make MenuCue compatible with the window and Tab
/// shortcuts BetterAndBetter users expect without overwriting an existing claimed key.
enum HotkeyBuiltInDefaults {
  static let currentVersion = 1

  static let bindings: [HotkeyBinding] = [
    binding("11111111-1111-4111-8111-111111111111", 126, "↑", [.command, .shift], "trackpad:window:maximize"),
    binding("22222222-2222-4222-8222-222222222222", 125, "↓", [.command, .shift], "trackpad:window:restore"),
    binding("33333333-3333-4333-8333-333333333333", 124, "→", [.command, .shift], "trackpad:window:nextDisplay"),
    binding("44444444-4444-4444-8444-444444444444", 33, "[", [.command, .shift], ActionCatalog.tabNavigationItemID(.previous)),
    binding("55555555-5555-4555-8555-555555555555", 30, "]", [.command, .shift], ActionCatalog.tabNavigationItemID(.next)),
    binding("66666666-6666-4666-8666-666666666666", 33, "[", [.command, .option], ActionCatalog.tabNavigationItemID(.previous)),
    binding("77777777-7777-4777-8777-777777777777", 30, "]", [.command, .option], ActionCatalog.tabNavigationItemID(.next)),
  ]

  static func merged(with existing: [HotkeyBinding]) -> [HotkeyBinding] {
    var result = existing
    for binding in bindings where !result.contains(where: { candidate in
      candidate.id == binding.id || candidate.shortcut.claimsSameKey(as: binding.shortcut)
    }) {
      result.append(binding)
    }
    return AppSettings.normalizedHotkeyBindings(result)
  }

  private static func binding(
    _ id: String,
    _ keyCode: UInt16,
    _ characters: String,
    _ modifiers: Set<TrackpadModifier>,
    _ actionItemID: String
  ) -> HotkeyBinding {
    HotkeyBinding(
      id: UUID(uuidString: id)!,
      shortcut: TrackpadKeyboardShortcut(
        keyCode: keyCode,
        characters: characters,
        modifiers: modifiers
      ),
      actionItemID: actionItemID
    )
  }
}

extension TrackpadKeyboardShortcut {
  /// Two shortcuts collide when the system would hand them the same press, which is a
  /// narrower question than being written the same way: the typed character is a label
  /// read off the keyboard layout, and `fn` is a modifier the hot-key table cannot see, so
  /// ⌘K and fn⌘K are one combination as far as the system is concerned.
  func claimsSameKey(as other: TrackpadKeyboardShortcut) -> Bool {
    keyCode == other.keyCode && carbonModifierMask == other.carbonModifierMask
  }

  /// The modifier mask the system hot-key table expects. `fn` has no bit here, which is
  /// why a combination cannot rely on it alone.
  var carbonModifierMask: UInt32 {
    var mask: UInt32 = 0
    if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
    if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
    if modifiers.contains(.option) { mask |= UInt32(optionKey) }
    if modifiers.contains(.control) { mask |= UInt32(controlKey) }
    return mask
  }
}
