import Foundation
import XCTest

@testable import MenuCue

/// The registry replaced the engine's per-kind switches, so it is now the thing that has
/// to stay exhaustive: a gesture kind with no recognizer would silently never fire.
final class TrackpadRecognizerRegistryTests: XCTestCase {
  func testEveryGestureKindHasExactlyOneRecognizer() {
    let kinds = TrackpadRecognizerRegistry.makeRecognizers().map(\.kind)

    XCTAssertEqual(
      Set(kinds),
      Set(TrackpadGestureKind.allCases),
      "a kind without a recognizer can be configured but can never fire"
    )
    XCTAssertEqual(kinds.count, Set(kinds).count, "two recognizers for one kind race each other")
  }

  func testRegistrationOrderKeepsThePerFrameFamiliesAheadOfTheCompletionFamilies() {
    let kinds = TrackpadRecognizerRegistry.makeRecognizers().map(\.kind)

    XCTAssertEqual(
      Array(kinds.prefix(2)),
      [.tipTap, .edgeContinuous],
      "registration order is the evaluation order; the per-frame families must stay first"
    )
  }

  func testOnlyThePerFrameFamiliesCarrySessionState() {
    let stateful = TrackpadRecognizerRegistry.makeRecognizers()
      .filter { $0.makeSessionState() != nil }
      .map(\.kind)

    XCTAssertEqual(
      Set(stateful),
      [.tipTap, .edgeContinuous],
      "a family that judges only completed sessions reads contact histories, not scratch space"
    )
  }

  func testSuppressionDeclarationsCoverEveryKind() {
    let expected: [TrackpadGestureKind: TrackpadInputSuppressionNeed] = [
      .contact: .optInLeftClick,
      .edgeContinuous: .scrollWheel,
      .swipe: .none,
      .edgeEntrySwipe: .none,
      .pinch: .none,
      .tipTap: .none,
      .fingerSwipe: .none,
      .drawing: .none,
    ]

    for kind in TrackpadGestureKind.allCases {
      XCTAssertEqual(
        TrackpadRecognizerRegistry.suppression(for: kind),
        expected[kind],
        kind.rawValue
      )
    }
  }

  /// Only the family whose fingers drag the cursor may hold it still, and the declaration
  /// has to survive projection into a match, which is all the dispatcher ever reads.
  func testOnlyTheContinuousEdgeFamilyFreezesThePointer() {
    let expected: [TrackpadGestureKind: Bool] = [
      .contact: false,
      .edgeContinuous: true,
      .swipe: false,
      .edgeEntrySwipe: false,
      .pinch: false,
      .tipTap: false,
      .fingerSwipe: false,
      .drawing: false,
    ]

    for kind in TrackpadGestureKind.allCases {
      XCTAssertEqual(
        TrackpadRecognizerRegistry.freezesPointer(for: kind),
        expected[kind],
        kind.rawValue
      )
      XCTAssertEqual(
        TrackpadGestureMatch(
          id: 1,
          rule: rule(kind: kind),
          direction: nil,
          continuousDelta: 0,
          timestamp: 0
        ).freezesPointer,
        expected[kind],
        kind.rawValue
      )
    }
  }

  func testSuppressionNeedsFollowTheEnabledRulesOnly() {
    let edge = rule(kind: .edgeContinuous)
    let tap = rule(kind: .contact)
    let swipe = rule(kind: .swipe)

    XCTAssertEqual(
      TrackpadRecognizerRegistry.suppressionNeeds(for: [swipe]),
      [],
      "a family with nothing to suppress must not cause a tap to be installed"
    )
    XCTAssertEqual(
      TrackpadRecognizerRegistry.suppressionNeeds(for: [edge, tap]),
      [.scrollWheel, .optInLeftClick]
    )
    XCTAssertEqual(
      TrackpadRecognizerRegistry.suppressionNeeds(for: [
        disabled(edge),
        disabled(tap),
        swipe,
      ]),
      [],
      "a disabled rule must not keep an event tap alive"
    )
  }

  /// The rule editor offers exactly what these declare, so a gap here becomes a rule the
  /// user can save and never trigger.
  func testFingerCountDeclarationsCoverEveryKindAndStayInsideHardwareLimits() {
    let expected: [TrackpadGestureKind: ClosedRange<Int>] = [
      .contact: 1...5,
      .swipe: 2...5,
      .edgeEntrySwipe: 2...5,
      .pinch: 2...4,
      .tipTap: 2...4,
      .fingerSwipe: 2...5,
      .drawing: 1...5,
      .edgeContinuous: 2...2,
    ]

    for kind in TrackpadGestureKind.allCases {
      let range = TrackpadRecognizerRegistry.supportedFingerCounts(for: kind)
      XCTAssertEqual(range, expected[kind], kind.rawValue)
      XCTAssertGreaterThanOrEqual(range.lowerBound, 1, kind.rawValue)
      XCTAssertLessThanOrEqual(range.upperBound, 5, kind.rawValue)
    }
  }

  /// Preset names are written to disk in English and localized for display, so both
  /// catalogs have to carry them or a Chinese user sees the English literal.
  func testEveryPresetNameIsTranslatedInBothCatalogs() throws {
    let english = try L10n.entries(for: "en")
    let chinese = try L10n.entries(for: "zh-Hans")

    for name in TrackpadGestureSettings.presetRules.map(\.name) {
      XCTAssertNotNil(english[name], name)
      let translated = try XCTUnwrap(chinese[name], name)
      XCTAssertNotEqual(translated, name, "\(name) is still the English literal in zh-Hans")
    }
  }

  func testShippedPresetsStillRequireNativeScrollSuppression() {
    XCTAssertTrue(
      TrackpadRecognizerRegistry
        .suppressionNeeds(for: TrackpadGestureSettings.presetRules)
        .contains(.scrollWheel),
      "the shipped continuous-edge presets are what install the scroll tap on first enable"
    )
  }

  private func rule(kind: TrackpadGestureKind) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: kind.rawValue,
      trigger: TrackpadGestureTrigger(kind: kind, fingerCount: 2),
      action: .system(.volumeUp)
    )
  }

  private func disabled(_ rule: TrackpadGestureRule) -> TrackpadGestureRule {
    var result = rule
    result.isEnabled = false
    return result
  }
}
