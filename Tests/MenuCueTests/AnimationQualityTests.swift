import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import MenuCue

final class AnimationQualityTests: XCTestCase {
  func testDefaultAndInvalidStoredValuesResolveToElegant() {
    let suite = "AnimationQualityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.load().animationQuality, .elegant)

    defaults.set("future-quality", forKey: "animationQuality.v1")
    XCTAssertEqual(store.load().animationQuality, .elegant)
  }

  func testAnimationQualityRoundTripsLocallyOnly() {
    let suite = "AnimationQualityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    var settings = store.load()

    settings.animationQuality = .full
    store.save(settings)

    XCTAssertEqual(store.load().animationQuality, .full)
    XCTAssertFalse(
      PortableSettingField.allCases.map(\.rawValue).contains("animationQuality"),
      "device-specific motion quality must not enter iCloud envelopes"
    )
  }

  func testMotionProfilesMapEveryPreset() {
    let full = MotionProfile(quality: .full)
    XCTAssertTrue(full.animatesNumeric(.primary))
    XCTAssertTrue(full.animatesNumeric(.secondary))
    XCTAssertEqual(full.navigationStyle, .spatial)
    XCTAssertTrue(full.usesMatchedGeometry)
    XCTAssertTrue(full.usesSymbolBounce)
    XCTAssertEqual(full.continuousFrameInterval ?? 0, 1 / 20, accuracy: 0.0001)
    XCTAssertEqual(full.statusClockMotion, .push)

    let elegant = MotionProfile(quality: .elegant)
    XCTAssertTrue(elegant.animatesNumeric(.primary))
    XCTAssertFalse(elegant.animatesNumeric(.secondary))
    XCTAssertEqual(elegant.navigationStyle, .spatial)
    XCTAssertTrue(elegant.usesMatchedGeometry)
    XCTAssertFalse(elegant.usesSymbolBounce)
    XCTAssertEqual(elegant.continuousFrameInterval ?? 0, 1 / 10, accuracy: 0.0001)
    XCTAssertEqual(elegant.statusClockMotion, .push)

    let minimal = MotionProfile(quality: .minimal)
    XCTAssertFalse(minimal.animatesNumeric(.primary))
    XCTAssertNil(minimal.barAnimation)
    XCTAssertNil(minimal.continuousFrameInterval)
    XCTAssertEqual(minimal.navigationStyle, .crossfade)
    XCTAssertFalse(minimal.usesMatchedGeometry)
    XCTAssertEqual(minimal.statusClockMotion, .none)
  }

  /// The clock switch is one transition per scroll, so it must not be priced at the cost of
  /// the tier that also turns on continuous redraw.
  func testDirectionalClockMotionDoesNotRequireContinuousRendering() {
    let elegant = MotionProfile(quality: .elegant)

    XCTAssertEqual(elegant.statusClockMotion, .push)
    XCTAssertNotEqual(
      elegant.continuousFrameInterval,
      MotionProfile(quality: .full).continuousFrameInterval,
      "the two tiers must stay distinguishable on rendering cost"
    )
  }

  /// A push that outlasts the cooldown would let a fast scroll start the next transition
  /// before the previous one lands.
  func testClockTransitionFitsInsideTheScrollCooldown() {
    for quality in AnimationQuality.allCases {
      let motion = MotionProfile(quality: quality)
      XCTAssertLessThanOrEqual(
        motion.statusClockTransitionDuration,
        StatusBarController.wheelSwitchCooldown,
        "\(quality) transition outlasts the scroll cooldown"
      )
    }
  }

  func testReduceMotionOverridesFullQuality() {
    let reduced = MotionProfile(quality: .full, reducesMotion: true)

    XCTAssertFalse(reduced.animatesNumeric(.primary))
    XCTAssertNil(reduced.pressAnimation)
    XCTAssertNil(reduced.barAnimation)
    XCTAssertNil(reduced.continuousFrameInterval)
    XCTAssertEqual(reduced.navigationStyle, .crossfade)
    XCTAssertFalse(reduced.usesMatchedGeometry)
    XCTAssertFalse(reduced.usesSymbolBounce)
    XCTAssertEqual(reduced.statusClockMotion, .none)
  }
}

@MainActor
final class MotionAwareProgressIndicatorTests: XCTestCase {
  func testMinimalAndReduceMotionUseStaticBusyIndicators() {
    _ = NSApplication.shared
    let full = host(
      MotionAwareProgressIndicator()
        .environment(\.menuCueMotion, MotionProfile(quality: .full))
    )
    XCTAssertNotNil(firstProgressIndicator(in: full))

    let minimal = host(
      MotionAwareProgressIndicator()
        .environment(\.menuCueMotion, MotionProfile(quality: .minimal))
    )
    XCTAssertNil(firstProgressIndicator(in: minimal))

    let reduced = host(
      MotionAwareProgressIndicator()
        .environment(
          \.menuCueMotion,
          MotionProfile(quality: .full, reducesMotion: true)
        )
    )
    XCTAssertNil(firstProgressIndicator(in: reduced))
  }

  private func host<V: View>(_ view: V) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    window.layoutIfNeeded()
    return hosting
  }

  private func firstProgressIndicator(in view: NSView) -> NSProgressIndicator? {
    if let indicator = view as? NSProgressIndicator { return indicator }
    for subview in view.subviews {
      if let indicator = firstProgressIndicator(in: subview) { return indicator }
    }
    return nil
  }

}
