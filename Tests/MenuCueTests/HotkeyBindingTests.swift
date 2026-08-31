import Carbon.HIToolbox
import Foundation
import XCTest

@testable import MenuCue

/// What a binding has to survive: a settings file written before a field existed, a
/// combination another binding already took, and an action the catalog has to find again
/// from nothing but a stored identifier.
final class HotkeyBindingTests: XCTestCase {
  func testABindingWrittenBeforeTheOtherFieldsExistedStillDecodes() throws {
    let identifier = UUID()
    let stored = """
      [{
        "id": "\(identifier.uuidString)",
        "shortcut": {"keyCode": 10, "characters": "K", "modifiers": ["command"]},
        "actionItemID": "builtin:darkMode"
      }]
      """

    let bindings = try JSONDecoder().decode(
      [HotkeyBinding].self,
      from: Data(stored.utf8)
    )

    XCTAssertEqual(bindings.count, 1)
    XCTAssertEqual(bindings.first?.id, identifier)
    XCTAssertEqual(bindings.first?.actionItemID, "builtin:darkMode")
    XCTAssertEqual(bindings.first?.name, "")
    XCTAssertEqual(
      bindings.first?.isEnabled, true,
      "a binding stored before the switch existed was one the user had turned on")
  }

  func testBuiltInDefaultsKeepTheirStableShortcutAndActionCatalog() {
    let bindings = HotkeyBuiltInDefaults.bindings
    let expected: [(keyCode: UInt16, modifiers: Set<TrackpadModifier>, actionItemID: String)] = [
      (126, [.command, .shift], "trackpad:window:maximize"),
      (125, [.command, .shift], "trackpad:window:restore"),
      (124, [.command, .shift], "trackpad:window:nextDisplay"),
      (33, [.command, .shift], "trackpad:tabNavigation:previous"),
      (30, [.command, .shift], "trackpad:tabNavigation:next"),
      (33, [.command, .option], "trackpad:tabNavigation:previous"),
      (30, [.command, .option], "trackpad:tabNavigation:next"),
    ]

    XCTAssertEqual(bindings.count, expected.count)
    for expectedBinding in expected {
      XCTAssertTrue(
        bindings.contains { binding in
          binding.shortcut.keyCode == expectedBinding.keyCode
            && binding.shortcut.modifiers == expectedBinding.modifiers
            && binding.actionItemID == expectedBinding.actionItemID
        },
        "the built-in shortcut must keep its promised key combination and action"
      )
    }
  }

  func testBuiltInDefaultsYieldToExistingIdentityAndCarbonKeyClaims() {
    let identityDefault = HotkeyBuiltInDefaults.bindings[0]
    let shortcutDefault = HotkeyBuiltInDefaults.bindings[1]
    let identityClaim = HotkeyBinding(
      id: identityDefault.id,
      name: "User identity claim",
      shortcut: shortcut(keyCode: 12, modifiers: [.command]),
      actionItemID: "builtin:darkMode"
    )
    let carbonKeyClaim = HotkeyBinding(
      name: "User key claim",
      shortcut: shortcutDefault.shortcut,
      actionItemID: "builtin:lockScreen"
    )

    let merged = HotkeyBuiltInDefaults.merged(with: [identityClaim, carbonKeyClaim])

    XCTAssertEqual(merged.first { $0.id == identityClaim.id }, identityClaim)
    XCTAssertEqual(
      merged.first { $0.shortcut.claimsSameKey(as: carbonKeyClaim.shortcut) },
      carbonKeyClaim,
      "a user-owned Carbon key must never be claimed again by a built-in binding"
    )
  }

  func testBuiltInDefaultsAreNotAddedAgainAfterTheirFirstMerge() {
    let once = HotkeyBuiltInDefaults.merged(with: [])

    XCTAssertEqual(
      HotkeyBuiltInDefaults.merged(with: once), once,
      "merging defaults repeatedly must not create duplicate hotkey registrations"
    )
  }

  func testBuiltInDefaultsAreAddedOnlyOnceAndStayRemovedAfterSaving() {
    let suiteName = "MenuCueTests.HotkeyBindingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults)

    var settings = store.load()
    XCTAssertEqual(
      settings.hotkeyBindings,
      HotkeyBuiltInDefaults.bindings,
      "the first load performs the one-time built-in hotkey migration"
    )
    settings.hotkeyBindings = []
    store.save(settings)

    XCTAssertEqual(
      SettingsStore(defaults: defaults).load().hotkeyBindings,
      [],
      "a user who removes every built-in shortcut must not get them back on the next load"
    )
  }

  func testTwoBindingsCannotShareAnIdentifier() {
    let shared = UUID()
    let bindings = AppSettings.normalizedHotkeyBindings([
      HotkeyBinding(id: shared, name: "First", actionItemID: "builtin:darkMode"),
      HotkeyBinding(id: shared, name: "Second", actionItemID: "builtin:lockScreen"),
    ])

    XCTAssertEqual(bindings.map(\.name), ["First"])
  }

  func testACombinationAlreadyTakenByAnotherBindingIsRefusedWithItsName() {
    let existing = HotkeyBinding(
      name: "Dark Mode",
      shortcut: shortcut(keyCode: 10, modifiers: [.command, .shift]),
      actionItemID: "builtin:darkMode"
    )
    let duplicate = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.shift, .command]),
      actionItemID: "builtin:lockScreen"
    )

    XCTAssertEqual(
      HotkeyBindingPolicy.validate(duplicate, against: [existing]),
      .conflict(name: "Dark Mode")
    )
    XCTAssertEqual(
      HotkeyBindingPolicy.validate(existing, against: [existing]),
      .valid,
      "a binding is not in conflict with the row it is being edited from"
    )
  }

  func testAConflictIsNamedByTheActionWhenTheBindingHasNoNameOfItsOwn() {
    let existing = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command]),
      actionItemID: "builtin:darkMode"
    )
    let duplicate = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command]),
      actionItemID: "builtin:lockScreen"
    )

    XCTAssertEqual(
      HotkeyBindingPolicy.validate(
        duplicate,
        against: [existing],
        actionTitles: ["builtin:darkMode": "Dark Mode"]
      ),
      .conflict(name: "Dark Mode")
    )
  }

  func testTheSameKeyWithDifferentModifiersIsADifferentShortcut() {
    let existing = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command]),
      actionItemID: "builtin:darkMode"
    )
    let other = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command, .option]),
      actionItemID: "builtin:lockScreen"
    )

    XCTAssertEqual(HotkeyBindingPolicy.validate(other, against: [existing]), .valid)
  }

  func testAddingFnToATakenCombinationIsStillTheSameCombination() {
    let existing = HotkeyBinding(
      name: "Dark Mode",
      shortcut: shortcut(keyCode: 10, modifiers: [.command]),
      actionItemID: "builtin:darkMode"
    )
    let withFunction = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command, .function]),
      actionItemID: "builtin:lockScreen"
    )

    XCTAssertEqual(
      HotkeyBindingPolicy.validate(withFunction, against: [existing]),
      .conflict(name: "Dark Mode"),
      "the hot-key table has no bit for fn, so the system would see one combination asked "
        + "for twice and refuse the second"
    )
  }

  func testAnIncompleteBindingSaysWhichPieceIsMissing() {
    let blank = HotkeyBinding(actionItemID: "builtin:darkMode")
    let bareKey = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: []),
      actionItemID: "builtin:darkMode"
    )
    let shiftOnly = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.shift]),
      actionItemID: "builtin:darkMode"
    )
    let functionOnly = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.function]),
      actionItemID: "builtin:darkMode"
    )
    let withoutAction = HotkeyBinding(shortcut: shortcut(keyCode: 10, modifiers: [.command]))

    XCTAssertEqual(HotkeyBindingPolicy.validate(blank, against: []), .missingShortcut)
    XCTAssertEqual(HotkeyBindingPolicy.validate(bareKey, against: []), .missingModifier)
    XCTAssertEqual(
      HotkeyBindingPolicy.validate(shiftOnly, against: []), .missingModifier,
      "⇧K is what typing a capital K sends, so a shift-only shortcut swallows ordinary input")
    XCTAssertEqual(
      HotkeyBindingPolicy.validate(functionOnly, against: []), .missingModifier,
      "fn has no bit in the system hot-key table, so it cannot be asked for at all")
    XCTAssertEqual(HotkeyBindingPolicy.validate(withoutAction, against: []), .missingAction)
    XCTAssertNotNil(HotkeyBindingValidation.missingModifier.message)
  }

  func testTheRegistrableListDropsTheSecondClaimOnOneCombination() {
    let first = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command]),
      actionItemID: "builtin:darkMode"
    )
    let duplicate = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command]),
      actionItemID: "builtin:lockScreen"
    )
    let disabled = HotkeyBinding(
      shortcut: shortcut(keyCode: 11, modifiers: [.command]),
      actionItemID: "builtin:darkMode",
      isEnabled: false
    )

    XCTAssertEqual(
      HotkeyBindingPolicy.registrable([first, duplicate, disabled]).map(\.id),
      [first.id]
    )
  }

  func testTheCarbonMaskCarriesEveryModifierTheSystemTableKnows() {
    let shortcut = shortcut(keyCode: 10, modifiers: [.command, .control, .option, .shift])

    XCTAssertEqual(
      shortcut.carbonModifierMask,
      UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey)
    )
    XCTAssertEqual(
      self.shortcut(keyCode: 10, modifiers: [.function]).carbonModifierMask, 0,
      "fn is the modifier the table has no bit for")
  }

  // MARK: - Catalog

  func testAStoredIdentifierFindsItsWayBackToSomethingRunnable() {
    for item in ActionCatalog.items(surface: .hotkey, shortcuts: ["Routine"]) {
      XCTAssertEqual(
        ActionCatalog.route(forItemID: item.id), item.route,
        "a binding stores \(item.id) and nothing else, so this is the only way back")
    }
    XCTAssertNil(ActionCatalog.route(forItemID: "trackpad:nonsense"))
  }

  func testTheHotkeySurfaceOffersOnlyActionsThatCarryTheirOwnConfiguration() {
    let hotkey = ActionCatalog.items(surface: .hotkey, shortcuts: ["Routine"])
    let parameterized: Set<TrackpadGestureActionKind> = [.keyboardShortcut, .open, .appleScript]

    for item in hotkey {
      guard case .trackpad(let action) = item.route else { continue }
      XCTAssertFalse(
        parameterized.contains(action.kind),
        "\(item.id) is registered once for a whole family, so a hotkey holding its identifier "
          + "would have no parameters to run with")
    }
    XCTAssertTrue(hotkey.contains { $0.id == "trackpad:window:nextDisplay" })
    XCTAssertTrue(hotkey.contains { $0.id == "builtin:darkMode" })
    XCTAssertTrue(hotkey.contains { $0.id == "shortcut:Routine" })
  }

  func testAnActionReportsTheShortcutsBoundToIt() {
    let item = ActionCatalog.builtInQuickActions.first { $0.id == "builtin:darkMode" }!
    let bound = HotkeyBinding(
      shortcut: shortcut(keyCode: 10, modifiers: [.command, .option]),
      actionItemID: "builtin:darkMode"
    )
    let elsewhere = HotkeyBinding(
      shortcut: shortcut(keyCode: 11, modifiers: [.command]),
      actionItemID: "builtin:lockScreen"
    )

    XCTAssertEqual(
      ActionCatalog.references(of: item, pinned: [], rules: [], hotkeys: [bound, elsewhere]),
      [.hotkey(shortcut: bound.shortcut.displayText)]
    )
    XCTAssertEqual(
      ActionCatalog.references(of: item, pinned: [], rules: []),
      [],
      "an action nothing points at still reports nothing"
    )
  }

  private func shortcut(
    keyCode: UInt16,
    modifiers: Set<TrackpadModifier>
  ) -> TrackpadKeyboardShortcut {
    TrackpadKeyboardShortcut(keyCode: keyCode, characters: "K", modifiers: modifiers)
  }
}
