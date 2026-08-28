import XCTest

@testable import MenuCue

final class TrackpadFeedbackPolicyTests: XCTestCase {
  /// Continuous adjustments were hidden here until it turned out nothing else reports
  /// them: the system bezel only answers to the media keys, and volume and brightness are
  /// set through their frameworks instead. The settings switch is the only gate now.
  func testHUDVisibilityFollowsTheSettingsSwitchAlone() {
    XCTAssertTrue(TrackpadFeedbackPolicy.shouldShowHUD(isEnabled: true))
    XCTAssertFalse(TrackpadFeedbackPolicy.shouldShowHUD(isEnabled: false))
  }

  /// The bug this replaces: the output was muted, every gesture raised the level without
  /// clearing the mute, and so the adjustment stayed silent and the readout stayed on
  /// "muted" no matter how far it was pushed. There was no way out of it from the trackpad.
  func testRaisingAMutedOutputTakesItOffMute() {
    XCTAssertTrue(TrackpadVolumePolicy.shouldUnmute(wasMuted: true, resultingScalar: 0.4))
    XCTAssertTrue(TrackpadVolumePolicy.shouldUnmute(wasMuted: true, resultingScalar: 0.01))

    XCTAssertFalse(
      TrackpadVolumePolicy.shouldUnmute(wasMuted: true, resultingScalar: 0),
      "an adjustment all the way down is silent either way, so mute is left as it was"
    )
    XCTAssertFalse(
      TrackpadVolumePolicy.shouldUnmute(wasMuted: false, resultingScalar: 0.4),
      "an output that was not muted is not something to change"
    )
  }

  /// The HUD draws a bar when it is given a level, so an adjustment that landed somewhere
  /// on a scale has to carry where, and everything else has to carry nothing.
  func testOnlyAnAdjustmentWithAScaleReportsALevel() {
    XCTAssertEqual(TrackpadActionExecutionResult.success("Volume 40%", level: 0.4).level, 0.4)
    XCTAssertNil(TrackpadActionExecutionResult.success("Sent keyboard shortcut.").level)
    XCTAssertNil(TrackpadActionExecutionResult.failure(key: "Nope.").level)
    XCTAssertNil(TrackpadActionExecutionResult.failure(message: "Nope.").level)
  }

  func testTheLevelBarClampsWhateverItIsHanded() {
    let bar = TrackpadFeedbackLevelBar(frame: NSRect(x: 0, y: 0, width: 100, height: 6))

    bar.level = 1.4
    XCTAssertEqual(bar.level, 1.4, "the bar stores what it was told")

    // Drawing is what has to survive an out-of-range value; it clamps rather than painting
    // outside its own bounds.
    bar.level = -0.5
    bar.draw(bar.bounds)
    bar.level = 2
    bar.draw(bar.bounds)
  }
}
