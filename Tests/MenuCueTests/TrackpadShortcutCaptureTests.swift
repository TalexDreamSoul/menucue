import AppKit
import XCTest

@testable import MenuCue

/// The editor used to ask for a virtual key code typed as a number. These cover the
/// translation that replaced it: whatever the user pressed has to come back as a shortcut
/// that both executes and reads correctly in the rule list.
final class TrackpadShortcutCaptureTests: XCTestCase {
  func testAPressedCombinationBecomesItsShortcut() {
    let shortcut = TrackpadShortcutCapture.shortcut(
      keyCode: 0,
      charactersIgnoringModifiers: "a",
      flags: [.command, .shift]
    )

    XCTAssertEqual(shortcut.keyCode, 0)
    XCTAssertEqual(shortcut.characters, "A")
    XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    XCTAssertEqual(shortcut.displayText, "⇧⌘A")
  }

  /// AppKit reports arrows and function keys as private-use scalars, which draw as an
  /// empty box wherever the rule list shows them.
  func testKeysWithoutAPrintableCharacterGetALegibleLabel() {
    let up = TrackpadShortcutCapture.label(keyCode: 126, charactersIgnoringModifiers: "\u{F700}")
    let f5 = TrackpadShortcutCapture.label(keyCode: 96, charactersIgnoringModifiers: "\u{F708}")
    let space = TrackpadShortcutCapture.label(keyCode: 49, charactersIgnoringModifiers: " ")

    XCTAssertEqual(up, "↑")
    XCTAssertEqual(f5, "F5")
    XCTAssertEqual(space, "Space")
  }

  func testAnUnmappedPrivateUseScalarIsDroppedRatherThanShownAsABox() {
    XCTAssertEqual(
      TrackpadShortcutCapture.label(keyCode: 200, charactersIgnoringModifiers: "\u{F729}"),
      ""
    )
  }

  /// Modifier keys arrive as their own key-down events. Recording one would store a
  /// shortcut that can never be pressed again, and Escape is how the user backs out.
  func testModifiersAndEscapeAreNotRecordableOnTheirOwn() {
    for keyCode: UInt16 in [53, 55, 56, 58, 59, 63] {
      XCTAssertFalse(TrackpadShortcutCapture.isRecordable(keyCode: keyCode), "\(keyCode)")
    }
    XCTAssertTrue(TrackpadShortcutCapture.isRecordable(keyCode: 0))
    XCTAssertTrue(TrackpadShortcutCapture.isRecordable(keyCode: 126))
  }

  func testEveryModifierFlagSurvivesTheRoundTrip() {
    XCTAssertEqual(
      TrackpadShortcutCapture.modifiers(from: [.command, .option, .control, .shift, .function]),
      [.command, .option, .control, .shift, .function]
    )
    XCTAssertEqual(TrackpadShortcutCapture.modifiers(from: []), [])
  }

  /// A shortcut recorded before this control existed has a key code and no characters, and
  /// still has to be readable rather than blank.
  func testAShortcutWithoutCharactersFallsBackToItsKeyCode() {
    let legacy = TrackpadKeyboardShortcut(keyCode: 42, characters: "", modifiers: [.control])

    XCTAssertFalse(legacy.isUnset)
    XCTAssertTrue(legacy.displayText.contains("42"))
    XCTAssertTrue(TrackpadKeyboardShortcut().isUnset)
  }
}
