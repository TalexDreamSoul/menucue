import AppKit
import SwiftUI

/// Turns a pressed key into a stored shortcut. Everything here is pure so the mapping can
/// be tested without an event loop; only the recorder view below touches AppKit.
enum TrackpadShortcutCapture {
  /// Keys that carry no printable character, or whose character is a private-use glyph
  /// that would render as a blank box in the rule list.
  private static let namedKeys: [UInt16: String] = [
    36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
    115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
  ]

  static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<TrackpadModifier> {
    var result: Set<TrackpadModifier> = []
    if flags.contains(.shift) { result.insert(.shift) }
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.command) { result.insert(.command) }
    if flags.contains(.function) { result.insert(.function) }
    return result
  }

  /// The label stored alongside the key code. Reading it off the event rather than off a
  /// table is what keeps a non-US layout showing the key the user actually pressed.
  static func label(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
    if let named = namedKeys[keyCode] { return named }
    guard let characters = charactersIgnoringModifiers, let first = characters.unicodeScalars.first
    else {
      return ""
    }
    // Private-use scalars are AppKit's encoding for function keys, never anything a user
    // would recognize on a keycap.
    guard !(0xF700...0xF8FF).contains(first.value), first.value >= 0x20 else { return "" }
    return characters.uppercased()
  }

  /// A press that only changed modifiers is not a shortcut yet, and a bare Escape is the
  /// gesture for giving up on recording.
  static func isRecordable(keyCode: UInt16) -> Bool {
    keyCode != 53 && keyCode != 55 && keyCode != 56 && keyCode != 58 && keyCode != 59
      && keyCode != 63
  }

  static func shortcut(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    flags: NSEvent.ModifierFlags
  ) -> TrackpadKeyboardShortcut {
    TrackpadKeyboardShortcut(
      keyCode: keyCode,
      characters: label(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers),
      modifiers: modifiers(from: flags)
    )
  }
}

extension TrackpadKeyboardShortcut {
  var isUnset: Bool { keyCode == 0 && characters.isEmpty && modifiers.isEmpty }

  /// What the rule list and the recorder both show, so a shortcut reads the same wherever
  /// it appears.
  var displayText: String {
    let key = characters.isEmpty ? L10n.format("key code %d", keyCode) : characters
    let symbols = modifiers
      .sorted { $0.settingsSortIndex < $1.settingsSortIndex }
      .map(\.symbol)
      .joined()
    return symbols + key
  }
}

/// Click, then press the combination. The editor used to ask for a virtual key code typed
/// as a number, which requires knowing a table nobody has memorized and which does not
/// survive a keyboard layout change.
struct TrackpadShortcutRecorder: View {
  @Binding var shortcut: TrackpadKeyboardShortcut

  @State private var isRecording = false
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 8) {
      Button(action: toggleRecording) {
        Text(buttonTitle)
          .frame(minWidth: 150)
      }
      .help("Click, then press the shortcut you want this gesture to send.")
      .accessibilityLabel("Keyboard shortcut")
      .accessibilityValue(shortcut.isUnset ? "" : shortcut.displayText)

      if !shortcut.isUnset {
        Button("Clear") {
          stopRecording()
          shortcut = TrackpadKeyboardShortcut()
        }
        .buttonStyle(.borderless)
      }
    }
    // A monitor that outlives the sheet would swallow every keystroke in the app.
    .onDisappear(perform: stopRecording)
  }

  private var buttonTitle: String {
    if isRecording { return L10n.string("Press a shortcut…") }
    return shortcut.isUnset ? L10n.string("Click to record") : shortcut.displayText
  }

  private func toggleRecording() {
    if isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  private func startRecording() {
    stopRecording()
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      // Escape leaves the existing shortcut alone; anything else is the new one. Either
      // way the key is consumed so recording cannot trigger the sheet's own buttons.
      if TrackpadShortcutCapture.isRecordable(keyCode: event.keyCode) {
        shortcut = TrackpadShortcutCapture.shortcut(
          keyCode: event.keyCode,
          charactersIgnoringModifiers: event.charactersIgnoringModifiers,
          flags: event.modifierFlags
        )
      }
      stopRecording()
      return nil
    }
  }

  private func stopRecording() {
    isRecording = false
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }
}
