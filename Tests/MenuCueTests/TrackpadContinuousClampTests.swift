import XCTest

@testable import MenuCue

/// The executor clamps one continuous emission at `maximumContinuousAmount`; a recognizer
/// whose per-frame step cap times its preset's step distance exceeds that ceiling loses
/// the difference with no way to earn it back, because the step ledger has already been
/// debited. These tests pin the factory presets inside the ceiling so raising either
/// constant alone fails loudly instead of truncating silently.
final class TrackpadContinuousClampTests: XCTestCase {
  func testFactoryContinuousPresetsFitInsideOneEmissionClamp() {
    let continuous = TrackpadGestureSettings.presetRules.filter {
      $0.trigger.kind == .edgeContinuous || $0.trigger.kind == .anchoredSlide
    }
    XCTAssertFalse(continuous.isEmpty, "The factory presets are expected to include continuous rules.")
    for rule in continuous {
      let cap: Int
      switch rule.trigger.kind {
      case .edgeContinuous: cap = TrackpadEdgeContinuousRecognizer.maximumStepsPerFrame
      case .anchoredSlide: cap = TrackpadAnchoredSlideRecognizer.maximumStepsPerFrame
      default: continue
      }
      let largestBurst = Double(cap) * rule.trigger.minimumDistance
      XCTAssertLessThanOrEqual(
        largestBurst,
        TrackpadActionExecutor.maximumContinuousAmount + 1e-9,
        "\(rule.name): a full burst of \(cap) steps × \(rule.trigger.minimumDistance) travel "
          + "would be truncated by the executor's clamp."
      )
    }
  }
}
