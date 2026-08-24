import Foundation
import XCTest

@testable import MenuCue

final class TrackpadGestureEngineTests: XCTestCase {
  private let editorContext = TrackpadGestureContext(bundleIdentifier: "com.example.editor")

  func testDisabledSettingsSuppressAnOtherwiseValidGesture() {
    let engine = TrackpadGestureEngine(
      settings: TrackpadGestureSettings(
        isEnabled: false,
        rules: [tipTapRule(selectedFingerIndex: 0, action: .volumeUp)]
      )
    )

    let matches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.25, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.32, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)]),
    ])

    XCTAssertTrue(matches.isEmpty, "disabled touch automation must not execute configured actions")
  }

  func testHeldRightAndCompletedLeftRecontactEmitsVolumeUpExactlyOnce() {
    let engine = makeEngine(rules: [tipTapRule(selectedFingerIndex: 0, action: .volumeUp)])

    let matches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.25, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.32, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)]),
      frame(5, 0.40, [contact(2, .out, 0.70, 0.50)]),
    ])

    XCTAssertEqual(matches.map { $0.rule.action.systemControl }, [.volumeUp])
  }

  func testHeldLeftAndCompletedRightRecontactEmitsVolumeDownExactlyOnce() {
    let engine = makeEngine(rules: [tipTapRule(selectedFingerIndex: 1, action: .volumeDown)])

    let matches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .touch, 0.30, 0.50), contact(2, .out, 0.70, 0.50)]),
      frame(3, 0.25, [contact(1, .touch, 0.30, 0.50), contact(3, .touch, 0.70, 0.50)]),
      frame(4, 0.32, [contact(1, .touch, 0.30, 0.50), contact(3, .out, 0.70, 0.50)]),
      frame(5, 0.40, [contact(1, .out, 0.30, 0.50)]),
    ])

    XCTAssertEqual(matches.map { $0.rule.action.systemControl }, [.volumeDown])
  }

  func testTwoFingerScrollAndSimultaneousLiftDoNotRecognizeTipTap() {
    let rule = tipTapRule(selectedFingerIndex: 0, action: .volumeUp)

    let scrollingEngine = makeEngine(rules: [rule])
    let scrollingMatches = consume(scrollingEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.10, [contact(1, .touch, 0.45, 0.65), contact(2, .touch, 0.85, 0.65)]),
      frame(3, 0.20, [contact(1, .out, 0.45, 0.65), contact(2, .out, 0.85, 0.65)]),
    ])

    let simultaneousLiftEngine = makeEngine(rules: [rule])
    let simultaneousLiftMatches = consume(simultaneousLiftEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .out, 0.70, 0.50)]),
    ])

    XCTAssertTrue(scrollingMatches.isEmpty, "ordinary two-finger scrolling must pass through")
    XCTAssertTrue(simultaneousLiftMatches.isEmpty, "a simultaneous release is not a selected-finger tap")
  }

  func testTipTapRejectsTimeoutAndExcessRecontactMovement() {
    let rule = tipTapRule(selectedFingerIndex: 0, action: .volumeUp)

    let timedOutEngine = makeEngine(rules: [rule])
    let timedOutMatches = consume(timedOutEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.90, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.96, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)]),
    ])

    let movedEngine = makeEngine(rules: [rule])
    let movedMatches = consume(movedEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.25, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.28, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.38, 0.50)]),
      frame(5, 0.32, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.38, 0.50)]),
    ])

    XCTAssertTrue(timedOutMatches.isEmpty, "a delayed recontact must not invoke Volume Up")
    XCTAssertTrue(movedMatches.isEmpty, "a recontact that moves outside tolerance must not invoke Volume Up")
  }

  func testThirdContactCannotCompleteTwoFingerTipTap() {
    let engine = makeEngine(rules: [tipTapRule(selectedFingerIndex: 0, action: .volumeUp)])

    let matches = consume(engine, [
      frame(1, 0, [
        contact(1, .touch, 0.20, 0.50),
        contact(2, .touch, 0.50, 0.50),
        contact(3, .touch, 0.80, 0.50),
      ]),
      frame(2, 0.20, [
        contact(1, .out, 0.20, 0.50),
        contact(2, .touch, 0.50, 0.50),
        contact(3, .touch, 0.80, 0.50),
      ]),
      frame(3, 0.25, [
        contact(2, .touch, 0.50, 0.50),
        contact(3, .touch, 0.80, 0.50),
        contact(4, .touch, 0.20, 0.50),
      ]),
      frame(4, 0.32, [
        contact(2, .touch, 0.50, 0.50),
        contact(3, .touch, 0.80, 0.50),
        contact(4, .out, 0.20, 0.50),
      ]),
    ])

    XCTAssertTrue(matches.isEmpty, "a two-finger rule must reject a session that saw a third contact")
  }

  func testResetCancelsPendingTipTapWithoutRetainingItsState() {
    let engine = makeEngine(rules: [tipTapRule(selectedFingerIndex: 0, action: .volumeUp)])

    _ = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
    ])
    engine.reset(deviceID: 1)

    let matches = consume(engine, [
      frame(3, 0.25, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.32, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)]),
    ])

    XCTAssertTrue(matches.isEmpty, "a cancelled session must not complete after reset")
  }

  func testDeviceAndTimestampBoundariesDoNotLeakPendingTipTapState() {
    let rule = tipTapRule(selectedFingerIndex: 0, action: .volumeUp)

    let timestampResetEngine = makeEngine(rules: [rule])
    _ = consume(timestampResetEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
    ])
    let timestampResetMatches = consume(timestampResetEngine, [
      frame(3, 0.10, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.16, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)]),
    ])

    let separateDeviceEngine = makeEngine(rules: [rule])
    _ = consume(separateDeviceEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
    ])
    let separateDeviceMatches = consume(separateDeviceEngine, [
      frame(3, 0.25, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)], deviceID: 2),
      frame(4, 0.32, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)], deviceID: 2),
    ])

    XCTAssertTrue(timestampResetMatches.isEmpty, "time reversal must begin a fresh recognition session")
    XCTAssertTrue(separateDeviceMatches.isEmpty, "a pending gesture on one device must not complete on another")
  }

  func testContinuousEdgesQuantizeTwoFingerCentroidAndHonorSensitivityAndInversion() {
    let cases: [(
      name: String,
      edge: TrackpadEdge,
      action: TrackpadSystemControl,
      isInverted: Bool,
      sensitivity: Double,
      firstStartY: Double,
      secondStartY: Double,
      firstEndY: Double,
      secondEndY: Double,
      expectedDelta: Double,
      expectedDirection: TrackpadDirection
    )] = [
      ("left edge uses its centroid when the second finger moves farther", .left, .continuousVolume, false, 1, 0.50, 0.52, 0.52, 0.61, 1, .up),
      ("left edge uses its centroid when the first finger moves farther", .left, .continuousVolume, false, 1, 0.50, 0.52, 0.59, 0.54, 1, .up),
      ("right edge downward brightness", .right, .continuousBrightness, false, 1, 0.555, 0.575, 0.535, 0.485, -1, .down),
      ("inverted left edge centroid", .left, .continuousVolume, true, 1, 0.50, 0.52, 0.52, 0.61, -1, .down),
      ("higher sensitivity applies more centroid steps", .left, .continuousVolume, false, 2, 0.50, 0.52, 0.52, 0.61, 2, .up),
    ]

    for testCase in cases {
      let firstX = testCase.edge == .left ? 0.02 : 0.98
      let secondX = testCase.edge == .left ? 0.04 : 0.96
      let rule = TrackpadGestureRule(
        name: testCase.name,
        trigger: TrackpadGestureTrigger(
          kind: .edgeContinuous,
          fingerCount: 2,
          edge: testCase.edge,
          isInverted: testCase.isInverted,
          minimumDistance: 0.04
        ),
        action: .system(testCase.action)
      )
      let engine = makeEngine(rules: [rule], sensitivity: testCase.sensitivity)

      let matches = consume(engine, [
        frame(1, 0, [
          contact(1, .touch, firstX, testCase.firstStartY),
          contact(2, .touch, secondX, testCase.secondStartY),
        ]),
        frame(2, 0.10, [
          contact(1, .touch, firstX, testCase.firstEndY),
          contact(2, .touch, secondX, testCase.secondEndY),
        ]),
      ])

      XCTAssertEqual(matches.map { $0.rule.action.systemControl }, [testCase.action], testCase.name)
      XCTAssertEqual(matches.map(\.continuousDelta), [testCase.expectedDelta], testCase.name)
      XCTAssertEqual(matches.compactMap(\.direction), [testCase.expectedDirection], testCase.name)
    }
  }

  func testContinuousEdgeKeepsAnEdgeCandidateUntilSecondFingerJoins() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.04
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [rule])

    let candidateMatches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.02, 0.50)]),
      frame(2, 0.05, [contact(1, .touch, 0.02, 0.53)]),
    ])
    let pairedMatches = consume(engine, [
      frame(3, 0.10, [
        contact(1, .touch, 0.02, 0.53),
        contact(2, .touch, 0.04, 0.55),
      ]),
      frame(4, 0.20, [
        contact(1, .touch, 0.02, 0.55),
        contact(2, .touch, 0.04, 0.65),
      ]),
    ])

    XCTAssertTrue(candidateMatches.isEmpty, "one edge finger is only a candidate and must not change volume")
    XCTAssertEqual(pairedMatches.map(\.continuousDelta), [1], "a second same-edge finger must complete the waiting candidate with centroid motion")
  }

  func testContinuousEdgeNeverEmitsForSingleFinger() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [rule])

    let matches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.02, 0.50)]),
      frame(2, 0.10, [contact(1, .touch, 0.02, 0.85)]),
      frame(3, 0.20, [contact(1, .out, 0.02, 0.85)]),
    ])

    XCTAssertTrue(matches.isEmpty, "a single edge finger must never invoke a continuous action")
  }

  func testContinuousEdgeCancelsWhenEitherFingerLeavesCorridorAndRateLimitsTwoFingerCentroidSteps() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let escapedCases: [(name: String, contacts: [TrackpadContact])] = [
      ("first finger", [
        contact(1, .touch, 0.16, 0.55),
        contact(2, .touch, 0.04, 0.57),
      ]),
      ("second finger", [
        contact(1, .touch, 0.04, 0.55),
        contact(2, .touch, 0.16, 0.57),
      ]),
    ]

    for testCase in escapedCases {
      let engine = makeEngine(rules: [rule])
      let matches = consume(engine, [
        frame(1, 0, [
          contact(1, .touch, 0.02, 0.50),
          contact(2, .touch, 0.04, 0.52),
        ]),
        frame(2, 0.10, testCase.contacts),
      ])

      XCTAssertTrue(
        matches.isEmpty,
        "the \(testCase.name) leaving its corridor must cancel adjustment even while the two-finger centroid remains inside"
      )
    }

    let rateLimitedEngine = makeEngine(rules: [rule])
    _ = consume(rateLimitedEngine, [
      frame(1, 0, [
        contact(1, .touch, 0.02, 0.50),
        contact(2, .touch, 0.04, 0.52),
      ]),
    ])
    let first = consume(rateLimitedEngine, [
      frame(2, 0.10, [
        contact(1, .touch, 0.02, 0.545),
        contact(2, .touch, 0.04, 0.565),
      ]),
    ])
    let duringCooldown = consume(rateLimitedEngine, [
      frame(3, 0.12, [
        contact(1, .touch, 0.02, 0.59),
        contact(2, .touch, 0.04, 0.61),
      ]),
    ])
    let afterCooldown = consume(rateLimitedEngine, [
      frame(4, 0.18, [
        contact(1, .touch, 0.02, 0.635),
        contact(2, .touch, 0.04, 0.655),
      ]),
    ])

    XCTAssertEqual(first.map(\.continuousDelta), [2], "two-finger centroid distance must quantize into bounded steps")
    XCTAssertTrue(duringCooldown.isEmpty, "continuous actions must not emit during the cooldown")
    XCTAssertEqual(afterCooldown.map(\.continuousDelta), [3], "a delayed two-finger backlog is capped to three steps")
  }

  func testSpecificApplicationRuleWinsOverAllApplicationsRule() {
    let allApplicationsRule = contactTapRule(
      name: "All apps",
      action: .volumeUp,
      applicationScope: .all
    )
    let editorRule = contactTapRule(
      name: "Editor only",
      action: .volumeDown,
      applicationScope: TrackpadApplicationScope(
        mode: .includedApplications,
        applications: [TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")]
      )
    )
    let engine = makeEngine(rules: [allApplicationsRule, editorRule])

    let matches = completedSingleFingerTap(engine, context: editorContext)

    XCTAssertEqual(matches.map { $0.rule.action.systemControl }, [.volumeDown])
  }

  func testModifierAndDeviceScopesGateRecognition() {
    let rule = contactTapRule(
      name: "Built-in Option tap",
      action: .volumeUp,
      requiredModifiers: [.option],
      deviceScope: .builtInOnly
    )
    let cases: [(name: String, isBuiltIn: Bool, modifiers: Set<TrackpadModifier>, expected: TrackpadSystemControl?)] = [
      ("matching built-in Option tap", true, [.option], .volumeUp),
      ("missing modifier", true, [], nil),
      ("external device", false, [.option], nil),
    ]

    for testCase in cases {
      let engine = makeEngine(rules: [rule])
      let matches = completedSingleFingerTap(
        engine,
        isBuiltIn: testCase.isBuiltIn,
        context: TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: testCase.modifiers)
      )

      if let expected = testCase.expected {
        XCTAssertEqual(matches.map { $0.rule.action.systemControl }, [expected], testCase.name)
      } else {
        XCTAssertTrue(matches.isEmpty, testCase.name)
      }
    }
  }

  func testDuplicateContactIdentifiersFailClosedWithoutRecognition() {
    let engine = makeEngine(rules: [tipTapRule(selectedFingerIndex: 0, action: .volumeUp)])

    let matches = consume(engine, [
      frame(1, 0, [contact(7, .touch, 0.30, 0.50), contact(7, .touch, 0.70, 0.50)]),
    ])

    XCTAssertTrue(matches.isEmpty, "a malformed frame with duplicate contact IDs must not invoke an action")
  }

  func testTipTapDoesNotEmitOnFirstLiftOrBeforeBothContactsHoldLongEnough() {
    let rule = tipTapRule(selectedFingerIndex: 0, action: .volumeUp)

    let firstLiftEngine = makeEngine(rules: [rule])
    let firstLiftMatches = consume(firstLiftEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
    ])

    let insufficientHoldEngine = makeEngine(rules: [rule])
    let insufficientHoldMatches = consume(insufficientHoldEngine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.10, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.15, [contact(2, .touch, 0.70, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.20, [contact(2, .touch, 0.70, 0.50), contact(3, .out, 0.30, 0.50)]),
    ])

    XCTAssertTrue(firstLiftMatches.isEmpty, "the initial lifted finger only arms a possible tip-tap")
    XCTAssertTrue(insufficientHoldMatches.isEmpty, "both contacts must be stable for the configured hold duration")
  }

  func testTipTapRejectsAnchorMovementOutsideTolerance() {
    let engine = makeEngine(rules: [tipTapRule(selectedFingerIndex: 0, action: .volumeUp)])

    let matches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.25, [contact(2, .touch, 0.80, 0.50), contact(3, .touch, 0.30, 0.50)]),
      frame(4, 0.32, [contact(2, .touch, 0.80, 0.50), contact(3, .out, 0.30, 0.50)]),
    ])

    XCTAssertTrue(matches.isEmpty, "a moved anchor must invalidate the selected-finger tip-tap")
  }

  func testContinuousEdgeRequiresBothFingerOriginsAndPositionsInsideTheSameCorridor() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [rule])

    let matches = consume(engine, [
      frame(1, 0, [
        contact(1, .touch, 0.02, 0.50),
        contact(2, .touch, 0.10, 0.52),
      ]),
      frame(2, 0.10, [
        contact(1, .touch, 0.02, 0.55),
        contact(2, .touch, 0.04, 0.65),
      ]),
      frame(3, 0.20, [
        contact(1, .touch, 0.02, 0.60),
        contact(2, .touch, 0.04, 0.70),
      ]),
    ])

    XCTAssertTrue(
      matches.isEmpty,
      "a finger that began outside the edge corridor must not become valid merely by moving its current position inside"
    )
  }

  func testContinuousEdgeReentryDoesNotReplayMotionOutsideTheCorridor() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [rule])

    let matches = consume(engine, [
      frame(1, 0, [
        contact(1, .touch, 0.02, 0.50),
        contact(2, .touch, 0.04, 0.52),
      ]),
      frame(2, 0.10, [
        contact(1, .touch, 0.04, 0.55),
        contact(2, .touch, 0.16, 0.57),
      ]),
      frame(3, 0.20, [
        contact(1, .touch, 0.02, 0.65),
        contact(2, .touch, 0.04, 0.67),
      ]),
    ])

    XCTAssertTrue(matches.isEmpty, "re-entering with either finger must not replay distance travelled after it left the edge corridor")
  }

  func testEdgeContinuousNeverEmitsAfterATwoFingerSessionDropsToOneFinger() {
    let edgeRule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [edgeRule])

    let matches = consume(engine, [
      frame(1, 0, [
        contact(1, .touch, 0.02, 0.50),
        contact(2, .touch, 0.04, 0.52),
      ]),
      frame(2, 0.05, [
        contact(1, .touch, 0.02, 0.51),
        contact(2, .touch, 0.04, 0.53),
      ]),
      frame(3, 0.10, [
        contact(1, .touch, 0.02, 0.52),
        contact(2, .out, 0.04, 0.53),
      ]),
      frame(4, 0.20, [contact(1, .touch, 0.02, 0.85)]),
      frame(5, 0.30, [
        contact(1, .touch, 0.02, 0.85),
        contact(2, .touch, 0.04, 0.87),
      ]),
      frame(6, 0.40, [
        contact(1, .touch, 0.02, 0.93),
        contact(2, .touch, 0.04, 0.95),
      ]),
      frame(7, 0.50, [
        contact(1, .out, 0.02, 0.93),
        contact(2, .out, 0.04, 0.95),
      ]),
    ])

    XCTAssertTrue(matches.isEmpty, "a two-finger edge session that drops to one must stay cancelled even if a second finger returns before lift")
  }

  func testContinuousEdgeNeverRearmsAfterAThirdFingerAppearsBeforeAllLift() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [rule])

    let matches = consume(engine, [
      frame(1, 0, [
        contact(1, .touch, 0.02, 0.50),
        contact(2, .touch, 0.04, 0.52),
      ]),
      frame(2, 0.05, [
        contact(1, .touch, 0.02, 0.51),
        contact(2, .touch, 0.04, 0.53),
        contact(3, .touch, 0.06, 0.54),
      ]),
      frame(3, 0.10, [
        contact(1, .touch, 0.02, 0.60),
        contact(2, .touch, 0.04, 0.70),
        contact(3, .out, 0.06, 0.54),
      ]),
      frame(4, 0.20, [
        contact(1, .touch, 0.02, 0.70),
        contact(2, .touch, 0.04, 0.80),
      ]),
    ])

    XCTAssertTrue(matches.isEmpty, "a third active finger must cancel the edge gesture rather than be ignored by a selected pair")
  }

  func testContinuousEdgeFailsOpenForDuplicateContactIDs() {
    let rule = TrackpadGestureRule(
      name: "Left edge volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
    let engine = makeEngine(rules: [rule])

    let matches = consume(engine, [
      frame(1, 0, [
        contact(1, .touch, 0.02, 0.50),
        contact(2, .touch, 0.04, 0.52),
      ]),
      frame(2, 0.10, [
        contact(1, .touch, 0.02, 0.55),
        contact(1, .touch, 0.04, 0.65),
      ]),
      frame(3, 0.20, [
        contact(1, .touch, 0.02, 0.65),
        contact(2, .touch, 0.04, 0.75),
      ]),
    ])

    XCTAssertTrue(matches.isEmpty, "a duplicate contact ID must fail open and must not let the edge session resume before every contact lifts")
  }

  func testTipTapEmissionPreventsAnchorLiftFromCompletingAnotherContactRule() {
    let tipTap = tipTapRule(selectedFingerIndex: 0, action: .volumeUp)
    let fallbackContact = TrackpadGestureRule(
      name: "Two-finger fallback",
      trigger: TrackpadGestureTrigger(
        kind: .contact,
        fingerCount: 2,
        contactGesture: .tap,
        maximumDuration: 0.6,
        movementTolerance: 0.035
      ),
      action: .system(.volumeDown)
    )
    let engine = makeEngine(rules: [tipTap, fallbackContact])

    let matches = consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(2, 0.20, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(3, 0.25, [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(4, 0.32, [contact(1, .out, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]),
      frame(5, 0.40, [contact(2, .out, 0.70, 0.50)]),
    ])

    XCTAssertEqual(matches.map { $0.rule.action.systemControl }, [.volumeUp])
  }

  func testDoubleTapStateDoesNotCrossDevicesResetsOrTimeReversal() {
    let doubleTapRule = TrackpadGestureRule(
      name: "One-finger double tap",
      trigger: TrackpadGestureTrigger(
        kind: .contact,
        fingerCount: 1,
        contactGesture: .doubleTap,
        maximumDuration: 0.5,
        movementTolerance: 0.035
      ),
      action: .system(.volumeUp)
    )

    let uninterruptedEngine = makeEngine(rules: [doubleTapRule])
    let uninterruptedMatches = consume(uninterruptedEngine, [
      frame(1, 0, [contact(1, .touch, 0.50, 0.50)]),
      frame(2, 0.05, [contact(1, .out, 0.50, 0.50)]),
      frame(3, 0.15, [contact(1, .touch, 0.50, 0.50)]),
      frame(4, 0.20, [contact(1, .out, 0.50, 0.50)]),
    ])

    let crossDeviceEngine = makeEngine(rules: [doubleTapRule])
    let crossDeviceMatches = consume(crossDeviceEngine, [
      frame(1, 0, [contact(1, .touch, 0.50, 0.50)], deviceID: 1),
      frame(2, 0.05, [contact(1, .out, 0.50, 0.50)], deviceID: 1),
      frame(3, 0.15, [contact(1, .touch, 0.50, 0.50)], deviceID: 2),
      frame(4, 0.20, [contact(1, .out, 0.50, 0.50)], deviceID: 2),
    ])

    let resetEngine = makeEngine(rules: [doubleTapRule])
    _ = consume(resetEngine, [
      frame(1, 0, [contact(1, .touch, 0.50, 0.50)]),
      frame(2, 0.05, [contact(1, .out, 0.50, 0.50)]),
    ])
    resetEngine.reset()
    let resetMatches = consume(resetEngine, [
      frame(3, 0.15, [contact(1, .touch, 0.50, 0.50)]),
      frame(4, 0.20, [contact(1, .out, 0.50, 0.50)]),
    ])

    let reversedTimeEngine = makeEngine(rules: [doubleTapRule])
    _ = consume(reversedTimeEngine, [
      frame(1, 1.00, [contact(1, .touch, 0.50, 0.50)]),
      frame(2, 1.05, [contact(1, .out, 0.50, 0.50)]),
    ])
    let reversedTimeMatches = consume(reversedTimeEngine, [
      frame(3, 0.15, [contact(1, .touch, 0.50, 0.50)]),
      frame(4, 0.20, [contact(1, .out, 0.50, 0.50)]),
    ])

    XCTAssertEqual(uninterruptedMatches.map { $0.rule.action.systemControl }, [.volumeUp])
    XCTAssertTrue(crossDeviceMatches.isEmpty, "a tap on another device cannot complete this device's double tap")
    XCTAssertTrue(resetMatches.isEmpty, "reset clears the pending first tap")
    XCTAssertTrue(reversedTimeMatches.isEmpty, "a time-reversed tap cannot complete a later first tap")
  }

  func testSlowSwipeFamiliesDoNotMatchWhileEquivalentFastGesturesDo() {
    let cases: [(
      name: String,
      rule: TrackpadGestureRule,
      start: [TrackpadContact],
      end: [TrackpadContact]
    )] = [
      (
        "swipe",
        TrackpadGestureRule(
          name: "Swipe",
          trigger: TrackpadGestureTrigger(
            kind: .swipe,
            fingerCount: 2,
            direction: .right,
            maximumDuration: 0.2,
            minimumDistance: 0.1
          ),
          action: .system(.volumeUp)
        ),
        [contact(1, .touch, 0.30, 0.40), contact(2, .touch, 0.50, 0.60)],
        [contact(1, .out, 0.50, 0.40), contact(2, .out, 0.70, 0.60)]
      ),
      (
        "edge-entry swipe",
        TrackpadGestureRule(
          name: "Edge entry",
          trigger: TrackpadGestureTrigger(
            kind: .edgeEntrySwipe,
            fingerCount: 2,
            direction: .right,
            edge: .left,
            maximumDuration: 0.2,
            minimumDistance: 0.1
          ),
          action: .system(.volumeUp)
        ),
        [contact(1, .touch, 0.02, 0.40), contact(2, .touch, 0.08, 0.60)],
        [contact(1, .out, 0.32, 0.40), contact(2, .out, 0.38, 0.60)]
      ),
      (
        "pinch",
        TrackpadGestureRule(
          name: "Pinch",
          trigger: TrackpadGestureTrigger(
            kind: .pinch,
            fingerCount: 2,
            pinchDirection: .outward,
            maximumDuration: 0.2,
            minimumDistance: 0.1
          ),
          action: .system(.volumeUp)
        ),
        [contact(1, .touch, 0.45, 0.50), contact(2, .touch, 0.55, 0.50)],
        [contact(1, .out, 0.25, 0.50), contact(2, .out, 0.75, 0.50)]
      ),
      (
        "selected-finger swipe",
        TrackpadGestureRule(
          name: "Selected finger",
          trigger: TrackpadGestureTrigger(
            kind: .fingerSwipe,
            fingerCount: 2,
            direction: .right,
            selectedFingerIndex: 0,
            maximumDuration: 0.2,
            movementTolerance: 0.035,
            minimumDistance: 0.1
          ),
          action: .system(.volumeUp)
        ),
        [contact(1, .touch, 0.30, 0.40), contact(2, .touch, 0.70, 0.60)],
        [contact(1, .out, 0.55, 0.40), contact(2, .out, 0.70, 0.60)]
      ),
    ]

    for testCase in cases {
      let fastEngine = makeEngine(rules: [testCase.rule])
      let fastMatches = consume(fastEngine, [
        frame(1, 0, testCase.start),
        frame(2, 0.10, testCase.end),
      ])

      let slowEngine = makeEngine(rules: [testCase.rule])
      let slowMatches = consume(slowEngine, [
        frame(1, 0, testCase.start),
        frame(2, 0.30, testCase.end),
      ])

      XCTAssertEqual(fastMatches.map { $0.rule.action.systemControl }, [.volumeUp], testCase.name)
      XCTAssertTrue(slowMatches.isEmpty, "\(testCase.name) must reject a duration beyond maximumDuration")
    }
  }

  func testHoldTapDrawingRequiresStationaryAnchorAndDelayedSecondPath() {
    let template = [
      TrackpadPoint(x: 0.35, y: 0.35),
      TrackpadPoint(x: 0.40, y: 0.35),
      TrackpadPoint(x: 0.45, y: 0.35),
      TrackpadPoint(x: 0.50, y: 0.35),
      TrackpadPoint(x: 0.50, y: 0.40),
      TrackpadPoint(x: 0.50, y: 0.45),
      TrackpadPoint(x: 0.50, y: 0.50),
      TrackpadPoint(x: 0.50, y: 0.55),
    ]
    let rule = TrackpadGestureRule(
      name: "Held drawing",
      trigger: TrackpadGestureTrigger(
        kind: .drawing,
        fingerCount: 2,
        drawingActivation: .holdTap,
        drawingTemplate: template,
        holdDuration: 0.18,
        movementTolerance: 0.03,
        minimumDrawingScore: 0.95
      ),
      action: .system(.volumeUp)
    )

    let validEngine = makeEngine(rules: [rule])
    let validMatches = consume(
      validEngine,
      holdTapDrawingFrames(template: template, secondPathStartsAt: 0.20, anchorPositionDuringPath: TrackpadPoint(x: 0.15, y: 0.50))
    )

    let earlyPathEngine = makeEngine(rules: [rule])
    let earlyPathMatches = consume(
      earlyPathEngine,
      holdTapDrawingFrames(template: template, secondPathStartsAt: 0.12, anchorPositionDuringPath: TrackpadPoint(x: 0.15, y: 0.50))
    )

    let movedAnchorEngine = makeEngine(rules: [rule])
    let movedAnchorMatches = consume(
      movedAnchorEngine,
      holdTapDrawingFrames(template: template, secondPathStartsAt: 0.20, anchorPositionDuringPath: TrackpadPoint(x: 0.20, y: 0.50))
    )

    XCTAssertEqual(validMatches.map { $0.rule.action.systemControl }, [.volumeUp])
    XCTAssertTrue(earlyPathMatches.isEmpty, "the drawing finger must begin after the anchor hold duration")
    XCTAssertTrue(movedAnchorMatches.isEmpty, "the hold-tap anchor must remain within movement tolerance")
  }

  func testDrawingGesturesHonorMaximumDurationForEveryActivation() {
    let template = [
      TrackpadPoint(x: 0.35, y: 0.35),
      TrackpadPoint(x: 0.40, y: 0.35),
      TrackpadPoint(x: 0.45, y: 0.35),
      TrackpadPoint(x: 0.50, y: 0.35),
      TrackpadPoint(x: 0.50, y: 0.40),
      TrackpadPoint(x: 0.50, y: 0.45),
      TrackpadPoint(x: 0.50, y: 0.50),
      TrackpadPoint(x: 0.50, y: 0.55),
    ]

    for activation in [
      TrackpadDrawingActivation.modifier,
      .bottomThumb,
      .holdTap,
    ] {
      let rule = TrackpadGestureRule(
        name: "\(activation.rawValue) drawing",
        trigger: TrackpadGestureTrigger(
          kind: .drawing,
          fingerCount: activation == .modifier ? 1 : 2,
          drawingActivation: activation,
          drawingTemplate: template,
          holdDuration: 0.18,
          maximumDuration: 0.4,
          movementTolerance: 0.03,
          minimumDrawingScore: 0.95
        ),
        action: .system(.volumeUp)
      )

      let fastEngine = makeEngine(rules: [rule])
      let fastMatches = consume(
        fastEngine,
        drawingFrames(template: template, activation: activation, pathStep: 0.01)
      )

      let slowEngine = makeEngine(rules: [rule])
      let slowMatches = consume(
        slowEngine,
        drawingFrames(template: template, activation: activation, pathStep: 0.06)
      )

      XCTAssertEqual(
        fastMatches.map { $0.rule.action.systemControl },
        [.volumeUp],
        activation.rawValue
      )
      XCTAssertTrue(
        slowMatches.isEmpty,
        "\(activation.rawValue) drawing must reject a matching path past maximumDuration"
      )
    }
  }

  func testEdgeScrollSuppressionKeepsOneFingerCandidatePassThroughUntilSecondFingerSharesEdge() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )

    var policy = TrackpadEdgeScrollSuppressionPolicy()
    let candidateDecision = policy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.08, 0.50)]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(candidateDecision.isSuppressing, "the first edge finger is only a candidate, so native scrolling must pass through")
    XCTAssertFalse(candidateDecision.drainsMomentum, "a candidate has not owned native scrolling and cannot drain momentum")

    let joinedDecision = policy.consume(
      frame: frame(2, 0.01, [
        contact(1, .touch, 0.08, 0.50),
        contact(2, .touch, 0.04, 0.52),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(joinedDecision.isSuppressing, "the second finger must begin suppression only when it joins the first in the same edge corridor")
    XCTAssertFalse(joinedDecision.drainsMomentum, "joining a valid pair must not drain native momentum")

    var outsideSecondPolicy = TrackpadEdgeScrollSuppressionPolicy()
    _ = outsideSecondPolicy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.04, 0.50)]),
      settings: settings,
      context: editorContext
    )
    let outsideSecondDecision = outsideSecondPolicy.consume(
      frame: frame(2, 0.01, [
        contact(1, .touch, 0.04, 0.50),
        contact(2, .touch, 0.10, 0.52),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(outsideSecondDecision.isSuppressing, "a second finger that starts outside the rule corridor must leave native scrolling alone")
    XCTAssertFalse(outsideSecondDecision.drainsMomentum)

    var nonContinuousRule = edgeContinuousRule()
    nonContinuousRule.trigger.kind = .edgeEntrySwipe
    var nonContinuousPolicy = TrackpadEdgeScrollSuppressionPolicy()
    _ = nonContinuousPolicy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.04, 0.50)]),
      settings: edgeScrollSuppressionSettings(
        isEnabled: true,
        edgeWidth: 0.08,
        rules: [nonContinuousRule]
      ),
      context: editorContext
    )
    XCTAssertFalse(
      nonContinuousPolicy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.04, 0.50),
          contact(2, .touch, 0.06, 0.52),
        ]),
        settings: edgeScrollSuppressionSettings(
          isEnabled: true,
          edgeWidth: 0.08,
          rules: [nonContinuousRule]
        ),
        context: editorContext
      ).isSuppressing,
      "only a configured continuous edge rule may suppress native scrolling"
    )
  }

  func testEdgeScrollSuppressionRequiresEnabledAppModifierAndDeviceScopedRule() {
    let editorOnly = TrackpadApplicationScope(
      mode: .includedApplications,
      applications: [TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")]
    )
    let scopedRule = edgeContinuousRule(
      requiredModifiers: [.option],
      applicationScope: editorOnly,
      deviceScope: .builtInOnly
    )
    let cases: [(
      name: String,
      isBuiltIn: Bool,
      context: TrackpadGestureContext,
      settingsEnabled: Bool,
      ruleEnabled: Bool,
      expected: Bool
    )] = [
      ("matching scoped pair", true, TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option]), true, true, true),
      ("wrong application", true, TrackpadGestureContext(bundleIdentifier: "com.example.other", modifiers: [.option]), true, true, false),
      ("missing modifier", true, TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: []), true, true, false),
      ("extra modifier", true, TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option, .shift]), true, true, false),
      ("external device", false, TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option]), true, true, false),
      ("disabled rule", true, TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option]), true, false, false),
      ("disabled settings", true, TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option]), false, true, false),
    ]

    for testCase in cases {
      var rule = scopedRule
      rule.isEnabled = testCase.ruleEnabled
      var policy = TrackpadEdgeScrollSuppressionPolicy()
      _ = policy.consume(
        frame: frame(1, 0, [contact(1, .touch, 0.04, 0.50)], isBuiltIn: testCase.isBuiltIn),
        settings: edgeScrollSuppressionSettings(
          isEnabled: testCase.settingsEnabled,
          edgeWidth: 0.08,
          rules: [rule]
        ),
        context: testCase.context
      )

      let decision = policy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.04, 0.50),
          contact(2, .touch, 0.06, 0.52),
        ], isBuiltIn: testCase.isBuiltIn),
        settings: edgeScrollSuppressionSettings(
          isEnabled: testCase.settingsEnabled,
          edgeWidth: 0.08,
          rules: [rule]
        ),
        context: testCase.context
      )

      XCTAssertEqual(decision.isSuppressing, testCase.expected, testCase.name)
      XCTAssertFalse(decision.drainsMomentum, "\(testCase.name) must not drain momentum before a valid pair naturally drops")
    }
  }

  func testEdgeScrollSuppressionKeepsAStableTwoFingerGestureInsideExpandedCorridor() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )
    var policy = TrackpadEdgeScrollSuppressionPolicy()

    XCTAssertFalse(
      policy.consume(
        frame: frame(1, 0, [contact(1, .touch, 0.07, 0.50)]),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )
    XCTAssertTrue(
      policy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.07, 0.50),
          contact(2, .touch, 0.05, 0.52),
        ]),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )
    XCTAssertTrue(
      policy.consume(
        frame: frame(3, 0.02, [
          contact(1, .touch, 0.13, 0.60),
          contact(2, .touch, 0.13, 0.62),
        ]),
        settings: settings,
        context: editorContext
      ).isSuppressing,
      "both stable pair members may remain inside the 0.06 expanded corridor"
    )
  }

  func testEdgeScrollSuppressionDisarmsWhenEitherFingerLeavesExpandedCorridorAndDoesNotRearmBeforeAllLift() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )
    let escapedCases: [(name: String, contacts: [TrackpadContact])] = [
      ("first finger", [
        contact(1, .touch, 0.15, 0.60),
        contact(2, .touch, 0.05, 0.62),
      ]),
      ("second finger", [
        contact(1, .touch, 0.07, 0.60),
        contact(2, .touch, 0.15, 0.62),
      ]),
    ]

    for testCase in escapedCases {
      var policy = TrackpadEdgeScrollSuppressionPolicy()
      _ = policy.consume(
        frame: frame(1, 0, [contact(1, .touch, 0.07, 0.50)]),
        settings: settings,
        context: editorContext
      )
      XCTAssertTrue(
        policy.consume(
          frame: frame(2, 0.01, [
            contact(1, .touch, 0.07, 0.50),
            contact(2, .touch, 0.05, 0.52),
          ]),
          settings: settings,
          context: editorContext
        ).isSuppressing
      )

      let escapedDecision = policy.consume(
        frame: frame(3, 0.02, testCase.contacts),
        settings: settings,
        context: editorContext
      )
      XCTAssertFalse(
        escapedDecision.isSuppressing,
        "the \(testCase.name) leaving the expanded corridor must restore native scrolling even when the pair centroid is still inside"
      )
      XCTAssertFalse(escapedDecision.drainsMomentum, "corridor invalidation is fail-open, not a valid momentum drain")

      let reenteredDecision = policy.consume(
        frame: frame(4, 0.03, [
          contact(1, .touch, 0.07, 0.70),
          contact(2, .touch, 0.05, 0.72),
        ]),
        settings: settings,
        context: editorContext
      )
      XCTAssertFalse(reenteredDecision.isSuppressing, "an invalidated pair must not reacquire suppression before every contact lifts")
      XCTAssertFalse(reenteredDecision.drainsMomentum)

      let allLiftedDecision = policy.consume(
        frame: frame(5, 0.04, [
          contact(1, .out, 0.07, 0.70),
          contact(2, .out, 0.05, 0.72),
        ]),
        settings: settings,
        context: editorContext
      )
      XCTAssertFalse(allLiftedDecision.isSuppressing)
      XCTAssertFalse(allLiftedDecision.drainsMomentum, "an invalidated pair must not manufacture a drain when it lifts")

      XCTAssertFalse(
        policy.consume(
          frame: frame(6, 0.05, [contact(3, .touch, 0.07, 0.50)]),
          settings: settings,
          context: editorContext
        ).isSuppressing
      )
      let freshPairDecision = policy.consume(
        frame: frame(7, 0.06, [
          contact(3, .touch, 0.07, 0.50),
          contact(4, .touch, 0.05, 0.52),
        ]),
        settings: settings,
        context: editorContext
      )
      XCTAssertTrue(freshPairDecision.isSuppressing, "a new two-finger edge pair may suppress only after all invalidated contacts lifted")
      XCTAssertFalse(freshPairDecision.drainsMomentum)
    }
  }

  func testEdgeScrollSuppressionLocksBothContactIdentitiesForTheActivePair() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )
    var policy = TrackpadEdgeScrollSuppressionPolicy()

    _ = policy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.07, 0.50)]),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(
      policy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.07, 0.50),
          contact(2, .touch, 0.05, 0.52),
        ]),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )

    let changedIDDecision = policy.consume(
      frame: frame(3, 0.02, [
        contact(1, .touch, 0.07, 0.60),
        contact(3, .touch, 0.05, 0.62),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(changedIDDecision.isSuppressing, "replacing either contact ID must fail open instead of treating a different pair as the owner")
    XCTAssertFalse(changedIDDecision.drainsMomentum)

    let restoredIDsDecision = policy.consume(
      frame: frame(4, 0.03, [
        contact(1, .touch, 0.07, 0.70),
        contact(2, .touch, 0.05, 0.72),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(restoredIDsDecision.isSuppressing, "a changed pair must remain blocked even if the original IDs reappear before all contacts lift")
    XCTAssertFalse(restoredIDsDecision.drainsMomentum)
  }

  func testEdgeScrollSuppressionDrainsOnlyWhenAValidPairNaturallyDropsToOneAndBlocksUntilAllLift() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )
    var policy = TrackpadEdgeScrollSuppressionPolicy()

    _ = policy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.07, 0.50)]),
      settings: settings,
      context: editorContext
    )
    let pairedDecision = policy.consume(
      frame: frame(2, 0.01, [
        contact(1, .touch, 0.07, 0.50),
        contact(2, .touch, 0.05, 0.52),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(pairedDecision.isSuppressing)
    XCTAssertFalse(pairedDecision.drainsMomentum)

    let oneFingerDecision = policy.consume(
      frame: frame(3, 0.02, [
        contact(1, .touch, 0.07, 0.60),
        contact(2, .out, 0.05, 0.52),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(oneFingerDecision.isSuppressing, "a valid pair must stop suppression as soon as it naturally drops to one finger")
    XCTAssertTrue(oneFingerDecision.drainsMomentum, "the natural two-to-one transition is the one valid point to drain momentum")

    let heldCandidateDecision = policy.consume(
      frame: frame(4, 0.03, [contact(1, .touch, 0.07, 0.70)]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(heldCandidateDecision.isSuppressing, "the remaining finger cannot re-own scrolling after the pair has dropped")
    XCTAssertFalse(heldCandidateDecision.drainsMomentum, "the drain is emitted once, not for every subsequent one-finger frame")

    let rejoinedDecision = policy.consume(
      frame: frame(5, 0.04, [
        contact(1, .touch, 0.07, 0.70),
        contact(3, .touch, 0.05, 0.72),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(rejoinedDecision.isSuppressing, "a replacement second finger remains blocked until every participant has lifted")
    XCTAssertFalse(rejoinedDecision.drainsMomentum)

    let allLiftedDecision = policy.consume(
      frame: frame(6, 0.05, [
        contact(1, .out, 0.07, 0.70),
        contact(3, .out, 0.05, 0.72),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(allLiftedDecision.isSuppressing)
    XCTAssertFalse(allLiftedDecision.drainsMomentum, "the pair already drained momentum at its valid two-to-one transition")

    XCTAssertFalse(
      policy.consume(
        frame: frame(7, 0.06, [contact(4, .touch, 0.07, 0.50)]),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )
    let freshPairDecision = policy.consume(
      frame: frame(8, 0.07, [
        contact(4, .touch, 0.07, 0.50),
        contact(5, .touch, 0.05, 0.52),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(freshPairDecision.isSuppressing, "a fully new pair may suppress after the prior sequence has completely ended")
    XCTAssertFalse(freshPairDecision.drainsMomentum)
  }

  func testEdgeScrollSuppressionFailsOpenForDuplicateIDsWithoutFakingMomentumDrain() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )
    var policy = TrackpadEdgeScrollSuppressionPolicy()

    _ = policy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.07, 0.50)]),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(
      policy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.07, 0.50),
          contact(2, .touch, 0.05, 0.52),
        ]),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )

    let malformedDecision = policy.consume(
      frame: frame(3, 0.02, [
        contact(1, .touch, 0.07, 0.60),
        contact(1, .touch, 0.05, 0.62),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(malformedDecision.isSuppressing, "a malformed frame with duplicate active IDs must fail open")
    XCTAssertFalse(malformedDecision.drainsMomentum, "malformed input must not manufacture a momentum-draining lift")

    let cleanButBlockedDecision = policy.consume(
      frame: frame(4, 0.03, [
        contact(1, .touch, 0.07, 0.70),
        contact(2, .touch, 0.05, 0.72),
      ]),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(cleanButBlockedDecision.isSuppressing, "a clean pair remains blocked until the malformed sequence fully lifts")
    XCTAssertFalse(cleanButBlockedDecision.drainsMomentum)
  }

  func testEdgeScrollSuppressionFailsOpenForConcurrentDevicesWithoutFakingMomentumDrain() {
    let settings = edgeScrollSuppressionSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      rules: [edgeContinuousRule()]
    )
    var policy = TrackpadEdgeScrollSuppressionPolicy()

    _ = policy.consume(
      frame: frame(1, 0, [contact(1, .touch, 0.07, 0.50)], deviceID: 1),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(
      policy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.07, 0.50),
          contact(2, .touch, 0.05, 0.52),
        ], deviceID: 1),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )

    let concurrentDeviceDecision = policy.consume(
      frame: frame(1, 0.02, [contact(3, .touch, 0.07, 0.50)], deviceID: 2),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(concurrentDeviceDecision.isSuppressing, "concurrent trackpads must fail open because native scroll events have no source-device identity")
    XCTAssertFalse(concurrentDeviceDecision.drainsMomentum, "a concurrent candidate is not an owner lift")

    let blockedOwnerDecision = policy.consume(
      frame: frame(3, 0.03, [
        contact(1, .touch, 0.07, 0.60),
        contact(2, .touch, 0.05, 0.62),
      ], deviceID: 1),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(blockedOwnerDecision.isSuppressing, "the original pair remains blocked after a concurrent device appeared")
    XCTAssertFalse(blockedOwnerDecision.drainsMomentum)

    let otherDeviceLiftDecision = policy.consume(
      frame: frame(2, 0.04, [contact(3, .out, 0.07, 0.50)], deviceID: 2),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(otherDeviceLiftDecision.isSuppressing)
    XCTAssertFalse(otherDeviceLiftDecision.drainsMomentum, "lifting a competing device must not fabricate a drain")

    let ownerLiftDecision = policy.consume(
      frame: frame(4, 0.05, [
        contact(1, .out, 0.07, 0.60),
        contact(2, .out, 0.05, 0.62),
      ], deviceID: 1),
      settings: settings,
      context: editorContext
    )
    XCTAssertFalse(ownerLiftDecision.isSuppressing)
    XCTAssertFalse(ownerLiftDecision.drainsMomentum, "an owner invalidated by concurrency must not drain momentum on lift")

    XCTAssertFalse(
      policy.consume(
        frame: frame(5, 0.06, [contact(4, .touch, 0.07, 0.50)], deviceID: 1),
        settings: settings,
        context: editorContext
      ).isSuppressing
    )
    let freshPairDecision = policy.consume(
      frame: frame(6, 0.07, [
        contact(4, .touch, 0.07, 0.50),
        contact(5, .touch, 0.05, 0.52),
      ], deviceID: 1),
      settings: settings,
      context: editorContext
    )
    XCTAssertTrue(freshPairDecision.isSuppressing, "a fresh pair may suppress only after all concurrent sequences have ended")
    XCTAssertFalse(freshPairDecision.drainsMomentum)
  }

  private func edgeScrollSuppressionSettings(
    isEnabled: Bool,
    edgeWidth: Double,
    rules: [TrackpadGestureRule]
  ) -> TrackpadGestureSettings {
    TrackpadGestureSettings(
      isEnabled: isEnabled,
      hapticFeedbackEnabled: false,
      feedbackHUDEnabled: false,
      suppressesClickAfterMultiFingerTap: false,
      edgeWidth: edgeWidth,
      sensitivity: 1,
      rules: rules
    )
  }

  private func edgeContinuousRule(
    isEnabled: Bool = true,
    requiredModifiers: Set<TrackpadModifier> = [],
    applicationScope: TrackpadApplicationScope = .all,
    deviceScope: TrackpadDeviceScope = .allSupported
  ) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: "Continuous edge",
      isEnabled: isEnabled,
      requiredModifiers: requiredModifiers,
      applicationScope: applicationScope,
      deviceScope: deviceScope,
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
  }

  private func makeEngine(
    rules: [TrackpadGestureRule],
    edgeWidth: Double = 0.08,
    sensitivity: Double = 1
  ) -> TrackpadGestureEngine {
    TrackpadGestureEngine(
      settings: TrackpadGestureSettings(
        isEnabled: true,
        edgeWidth: edgeWidth,
        sensitivity: sensitivity,
        rules: rules
      )
    )
  }

  private func tipTapRule(
    selectedFingerIndex: Int,
    action: TrackpadSystemControl
  ) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: "Selected finger tap",
      trigger: TrackpadGestureTrigger(
        kind: .tipTap,
        fingerCount: 2,
        selectedFingerIndex: selectedFingerIndex,
        holdDuration: 0.18,
        maximumDuration: 0.65,
        movementTolerance: 0.035
      ),
      action: .system(action)
    )
  }

  private func contactTapRule(
    name: String,
    action: TrackpadSystemControl,
    applicationScope: TrackpadApplicationScope = .all,
    requiredModifiers: Set<TrackpadModifier> = [],
    deviceScope: TrackpadDeviceScope = .allSupported
  ) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: name,
      requiredModifiers: requiredModifiers,
      applicationScope: applicationScope,
      deviceScope: deviceScope,
      trigger: TrackpadGestureTrigger(
        kind: .contact,
        fingerCount: 1,
        contactGesture: .tap,
        maximumDuration: 0.5,
        movementTolerance: 0.035
      ),
      action: .system(action)
    )
  }

  private func holdTapDrawingFrames(
    template: [TrackpadPoint],
    secondPathStartsAt: TimeInterval,
    anchorPositionDuringPath: TrackpadPoint,
    pathStep: TimeInterval = 0.01
  ) -> [TrackpadFrame] {
    let anchorStart = TrackpadPoint(x: 0.15, y: 0.50)
    var frames = [frame(1, 0, [contact(1, .touch, anchorStart.x, anchorStart.y)])]

    for (index, point) in template.enumerated() {
      frames.append(
        frame(
          Int32(index + 2),
          secondPathStartsAt + Double(index) * pathStep,
          [
            contact(1, .touch, anchorPositionDuringPath.x, anchorPositionDuringPath.y),
            contact(2, .touch, point.x, point.y),
          ]
        )
      )
    }

    guard let finalPoint = template.last else { return frames }
    frames.append(
      frame(
        Int32(template.count + 2),
        secondPathStartsAt + Double(template.count) * pathStep,
        [
          contact(1, .out, anchorPositionDuringPath.x, anchorPositionDuringPath.y),
          contact(2, .out, finalPoint.x, finalPoint.y),
        ]
      )
    )
    return frames
  }

  private func drawingFrames(
    template: [TrackpadPoint],
    activation: TrackpadDrawingActivation,
    pathStep: TimeInterval
  ) -> [TrackpadFrame] {
    guard let finalPoint = template.last else { return [] }

    switch activation {
    case .modifier:
      var frames: [TrackpadFrame] = []
      for (index, point) in template.enumerated() {
        frames.append(
          frame(
            Int32(index + 1),
            Double(index) * pathStep,
            [contact(1, .touch, point.x, point.y)]
          )
        )
      }
      frames.append(
        frame(
          Int32(template.count + 1),
          Double(template.count) * pathStep,
          [contact(1, .out, finalPoint.x, finalPoint.y)]
        )
      )
      return frames

    case .bottomThumb:
      var frames: [TrackpadFrame] = []
      for (index, point) in template.enumerated() {
        frames.append(
          frame(
            Int32(index + 1),
            Double(index) * pathStep,
            [
              contact(1, .touch, 0.10, 0.05),
              contact(2, .touch, point.x, point.y),
            ]
          )
        )
      }
      frames.append(
        frame(
          Int32(template.count + 1),
          Double(template.count) * pathStep,
          [
            contact(1, .out, 0.10, 0.05),
            contact(2, .out, finalPoint.x, finalPoint.y),
          ]
        )
      )
      return frames

    case .holdTap:
      return holdTapDrawingFrames(
        template: template,
        secondPathStartsAt: 0.20,
        anchorPositionDuringPath: TrackpadPoint(x: 0.15, y: 0.50),
        pathStep: pathStep
      )
    }
  }

  private func completedSingleFingerTap(
    _ engine: TrackpadGestureEngine,
    isBuiltIn: Bool = true,
    context: TrackpadGestureContext
  ) -> [TrackpadGestureMatch] {
    consume(engine, [
      frame(1, 0, [contact(1, .touch, 0.50, 0.50)], isBuiltIn: isBuiltIn),
      frame(2, 0.10, [contact(1, .out, 0.50, 0.50)], isBuiltIn: isBuiltIn),
    ], context: context)
  }

  private func consume(
    _ engine: TrackpadGestureEngine,
    _ frames: [TrackpadFrame],
    context: TrackpadGestureContext? = nil
  ) -> [TrackpadGestureMatch] {
    var matches: [TrackpadGestureMatch] = []
    for frame in frames {
      matches += engine.consume(frame: frame, context: context ?? editorContext)
    }
    return matches
  }

  private func frame(
    _ number: Int32,
    _ timestamp: TimeInterval,
    _ contacts: [TrackpadContact],
    deviceID: UInt64 = 1,
    isBuiltIn: Bool = true
  ) -> TrackpadFrame {
    TrackpadFrame(
      deviceID: deviceID,
      isBuiltIn: isBuiltIn,
      timestamp: timestamp,
      frameNumber: number,
      contacts: contacts
    )
  }

  private func contact(
    _ id: Int32,
    _ state: TrackpadContactState,
    _ x: Double,
    _ y: Double
  ) -> TrackpadContact {
    TrackpadContact(id: id, state: state, position: TrackpadPoint(x: x, y: y))
  }
}

final class TrackpadGestureSettingsPersistenceTests: XCTestCase {
  func testPresetCatalogCoversTheRequestedTipTapAndEdgeActions() throws {
    let presets = TrackpadGestureSettings.presetRules

    XCTAssertEqual(presets.count, 4)

    let leftTipTap = try XCTUnwrap(presets.first {
      $0.trigger.kind == .tipTap && $0.trigger.selectedFingerIndex == 0
    })
    let rightTipTap = try XCTUnwrap(presets.first {
      $0.trigger.kind == .tipTap && $0.trigger.selectedFingerIndex == 1
    })
    let leftEdge = try XCTUnwrap(presets.first {
      $0.trigger.kind == .edgeContinuous && $0.trigger.edge == .left
    })
    let rightEdge = try XCTUnwrap(presets.first {
      $0.trigger.kind == .edgeContinuous && $0.trigger.edge == .right
    })

    XCTAssertEqual(leftTipTap.action.systemControl, .volumeUp)
    XCTAssertEqual(rightTipTap.action.systemControl, .volumeDown)
    XCTAssertEqual(leftEdge.action.systemControl, .continuousVolume)
    XCTAssertEqual(rightEdge.action.systemControl, .continuousBrightness)
    XCTAssertEqual(leftEdge.trigger.fingerCount, 2, "the default left continuous-edge rule must require a deliberate two-finger gesture")
    XCTAssertEqual(rightEdge.trigger.fingerCount, 2, "the default right continuous-edge rule must require a deliberate two-finger gesture")
  }

  func testContinuousEdgeNormalizesEveryConfiguredFingerCountToTwo() {
    for suppliedCount in [0, 1, 2, 3, 5] {
      let normalized = TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: suppliedCount
      ).normalized

      XCTAssertEqual(
        normalized.fingerCount,
        2,
        "continuous edge configuration \(suppliedCount) must normalize to exactly two fingers"
      )
    }
  }

  func testPersistedOutOfRangeValuesAndDuplicateRuleIDsNormalizeIndependently() throws {
    let suite = "TrackpadGestureSettingsPersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let sharedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    var first = TrackpadGestureRule(
      id: sharedID,
      name: "First",
      trigger: TrackpadGestureTrigger(kind: .contact),
      action: .system(.volumeUp)
    )
    var duplicate = TrackpadGestureRule(
      id: sharedID,
      name: "Second",
      trigger: TrackpadGestureTrigger(kind: .contact),
      action: .system(.volumeDown)
    )
    first.trigger.fingerCount = 0
    first.trigger.minimumDistance = 9
    duplicate.trigger.holdDuration = 0
    duplicate.trigger.maximumDuration = 9

    var untrusted = TrackpadGestureSettings(isEnabled: true, rules: [first, duplicate])
    untrusted.edgeWidth = 9
    untrusted.sensitivity = -1
    defaults.set(try JSONEncoder().encode(untrusted), forKey: "trackpadGestureSettings.v1")

    let normalized = SettingsStore(defaults: defaults).load().trackpadGestureSettings

    XCTAssertEqual(normalized.edgeWidth, 0.2, accuracy: 0.000_001)
    XCTAssertEqual(normalized.sensitivity, 0.25, accuracy: 0.000_001)
    let normalizedFirst = try XCTUnwrap(normalized.rules.first)
    let normalizedSecond = try XCTUnwrap(normalized.rules.dropFirst().first)
    XCTAssertEqual(normalized.rules.map(\.id).count, Set(normalized.rules.map(\.id)).count)
    XCTAssertEqual(normalizedFirst.id, sharedID)
    XCTAssertNotEqual(normalizedSecond.id, sharedID)
    XCTAssertEqual(normalizedFirst.trigger.fingerCount, 1)
    XCTAssertEqual(normalizedFirst.trigger.minimumDistance, 0.8, accuracy: 0.000_001)
    XCTAssertEqual(normalizedSecond.trigger.holdDuration, 0.08, accuracy: 0.000_001)
    XCTAssertEqual(normalizedSecond.trigger.maximumDuration, 3, accuracy: 0.000_001)
  }

  func testTrackpadRulesRoundTripThroughLocalStoreWithoutPortableEnvelope() {
    let suite = "TrackpadGestureSettingsPersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    let configuredRules = [
      TrackpadGestureRule(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        name: "Built-in editor swipe",
        requiredModifiers: [.option],
        applicationScope: TrackpadApplicationScope(
          mode: .includedApplications,
          applications: [TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")]
        ),
        deviceScope: .builtInOnly,
        trigger: TrackpadGestureTrigger(
          kind: .swipe,
          fingerCount: 3,
          direction: .left,
          minimumDistance: 0.12
        ),
        action: .system(.brightnessDown)
      )
    ]
    let configured = TrackpadGestureSettings(
      isEnabled: true,
      hapticFeedbackEnabled: false,
      feedbackHUDEnabled: false,
      suppressesClickAfterMultiFingerTap: true,
      edgeWidth: 0.12,
      sensitivity: 1.5,
      rules: configuredRules
    )
    settings.trackpadGestureSettings = configured
    store.save(settings)

    XCTAssertEqual(SettingsStore(defaults: defaults).load().trackpadGestureSettings, configured)
    XCTAssertFalse(
      PortableSettingField.allCases.map(\.rawValue).contains("trackpadGestureSettings"),
      "trackpad rules refer to local devices, applications, and permissions"
    )
  }

  func testEmptyExcludedScopeRetainsItsModeAndCanExcludeALaterApplication() {
    var scope = TrackpadApplicationScope(
      mode: .excludedApplications,
      applications: []
    ).normalized

    XCTAssertEqual(scope.mode, .excludedApplications)
    XCTAssertTrue(scope.matches(bundleIdentifier: "com.example.editor"))

    scope.applications.append(
      TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")
    )
    let configured = scope.normalized

    XCTAssertEqual(configured.mode, .excludedApplications)
    XCTAssertFalse(configured.matches(bundleIdentifier: "com.example.editor"))
    XCTAssertTrue(configured.matches(bundleIdentifier: "com.example.other"))
  }
}
