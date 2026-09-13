import Foundation
import XCTest

@testable import MenuCue

/// What restoring the built-in shortcuts has to protect: the user's own bindings survive,
/// a key the user already claimed is never taken back, and bringing the defaults back is a
/// one-shot operation rather than something every merge repeats.
final class HotkeyBuiltInDefaultsTests: XCTestCase {
  func testAnEmptyListIsMissingEveryDefault() {
    XCTAssertEqual(HotkeyBuiltInDefaults.missing(from: []), HotkeyBuiltInDefaults.bindings)
  }

  func testACoveredListIsMissingNothing() {
    XCTAssertEqual(HotkeyBuiltInDefaults.missing(from: HotkeyBuiltInDefaults.bindings), [])
    XCTAssertEqual(
      HotkeyBuiltInDefaults.missing(from: HotkeyBuiltInDefaults.merged(with: [])),
      [],
      "an already-merged list must make the next restore a no-op")
  }

  /// Deleting one built-in shortcut has to bring back exactly that one; a restore that
  /// returns its neighbours too, or none at all, is the failure this guards.
  func testRemovingOneDefaultReturnsOnlyThatDefault() {
    for removedIndex in HotkeyBuiltInDefaults.bindings.indices {
      var remaining = HotkeyBuiltInDefaults.bindings
      remaining.remove(at: removedIndex)

      XCTAssertEqual(
        HotkeyBuiltInDefaults.missing(from: remaining),
        [HotkeyBuiltInDefaults.bindings[removedIndex]],
        "deleting built-in shortcut #\(removedIndex) must bring back only that one")
    }
  }

  /// The non-destructive half of the contract: a user shortcut that took a built-in key
  /// keeps it, and only that default is withheld.
  func testAUserShortcutThatTookADefaultsKeyKeepsIt() {
    let taken = HotkeyBuiltInDefaults.bindings[1]
    let userClaim = HotkeyBinding(
      name: "My shortcut",
      shortcut: taken.shortcut,
      actionItemID: "builtin:darkMode")

    let missing = HotkeyBuiltInDefaults.missing(from: [userClaim])

    XCTAssertFalse(
      missing.contains { $0.shortcut.claimsSameKey(as: userClaim.shortcut) },
      "restoring must never ask for a key the user's own shortcut already holds")
    XCTAssertEqual(
      missing.count,
      HotkeyBuiltInDefaults.bindings.count - 1,
      "every default other than the one the user claimed still comes back")
  }

  func testMergedKeepsEveryExistingBindingAndClaimsNoKeyTwice() {
    let identityClaim = HotkeyBinding(
      id: HotkeyBuiltInDefaults.bindings[0].id,
      name: "User identity claim",
      shortcut: TrackpadKeyboardShortcut(keyCode: 13, characters: "K", modifiers: [.command]),
      actionItemID: "builtin:darkMode")
    let keyClaim = HotkeyBinding(
      name: "User key claim",
      shortcut: HotkeyBuiltInDefaults.bindings[1].shortcut,
      actionItemID: "builtin:lockScreen")
    let unrelated = HotkeyBinding(
      name: "User shortcut",
      shortcut: TrackpadKeyboardShortcut(keyCode: 12, characters: "K", modifiers: [.command]),
      actionItemID: "builtin:sleepDisplay")

    let merged = HotkeyBuiltInDefaults.merged(with: [identityClaim, keyClaim, unrelated])

    for existing in [identityClaim, keyClaim, unrelated] {
      XCTAssertTrue(
        merged.contains(existing),
        "a restore must never drop a shortcut the user already had")
    }
    for (index, binding) in merged.enumerated() {
      for other in merged[(index + 1)...] {
        XCTAssertFalse(
          binding.shortcut.claimsSameKey(as: other.shortcut),
          "two bindings in the merged list would fight over one key press")
      }
    }
  }
}
