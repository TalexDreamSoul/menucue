import AppKit

/// Keeps physical feedback at the AppKit boundary so SwiftUI interactions remain declarative.
enum MenuCueHaptics {
  static func performAlignment() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }
}
