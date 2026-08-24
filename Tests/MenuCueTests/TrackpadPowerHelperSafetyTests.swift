import AppKit
import XCTest
@testable import MenuCue

final class TrackpadEdgeSafetyRegressionTests: XCTestCase {
  func testOwnerFailsOpenAndRemainsBlockedForDuplicateOrUnseenEndingContacts() {
    let settings = edgeSuppressionSettings()
    let cases: [(name: String, malformedContacts: [TrackpadContact])] = [
      (
        "duplicate ending ID",
        [
          contact(1, .touch, 0.07, 0.60),
          contact(2, .touch, 0.05, 0.62),
          contact(2, .out, 0.05, 0.62),
        ]
      ),
      (
        "unseen ending ID",
        [
          contact(1, .touch, 0.07, 0.60),
          contact(2, .touch, 0.05, 0.62),
          contact(3, .out, 0.03, 0.64),
        ]
      ),
    ]

    for testCase in cases {
      var policy = TrackpadEdgeScrollSuppressionPolicy()
      XCTAssertTrue(
        policy.consume(frame:
          frame(1, 0, [
            contact(1, .touch, 0.07, 0.50),
            contact(2, .touch, 0.05, 0.52),
          ]),
          settings: settings,
          context: edgeContext
        ).isSuppressing,
        "\(testCase.name): setup must establish the two-contact owner"
      )

      let malformedDecision = policy.consume(frame:
        frame(2, 0.01, testCase.malformedContacts),
        settings: settings,
        context: edgeContext
      )
      XCTAssertFalse(
        malformedDecision.isSuppressing,
        "\(testCase.name): every full-frame contact ID must be owned before native scroll is suppressed"
      )
      XCTAssertFalse(
        malformedDecision.drainsMomentum,
        "\(testCase.name): malformed ownership must not masquerade as a natural lift"
      )

      XCTAssertFalse(
        policy.consume(frame:
          frame(3, 0.02, [
            contact(1, .touch, 0.07, 0.70),
            contact(2, .touch, 0.05, 0.72),
          ]),
          settings: settings,
          context: edgeContext
        ).isSuppressing,
        "\(testCase.name): the former pair must stay blocked until every contact lifts"
      )
    }
  }

  func testHoverContactCannotOwnOrDispatchContinuousEdgeUntilAllContactsLift() {
    let settings = edgeSuppressionSettings()
    var policy = TrackpadEdgeScrollSuppressionPolicy()

    let hoverDecision = policy.consume(
      frame: frame(1, 0, [
        contact(1, .touch, 0.07, 0.50),
        contact(2, .hover, 0.05, 0.52),
      ]),
      settings: settings,
      context: edgeContext
    )
    XCTAssertFalse(
      hoverDecision.isSuppressing,
      "a hover contact is not a second touching finger and must not own native scrolling"
    )
    XCTAssertFalse(
      hoverDecision.drainsMomentum,
      "a rejected hover contact must not manufacture a natural lift"
    )

    let continuousMatch = gestureMatch(
      TrackpadGestureRule(
        name: "Continuous edge",
        trigger: TrackpadGestureTrigger(
          kind: .edgeContinuous,
          fingerCount: 2,
          edge: .left,
          minimumDistance: 0.02
        ),
        action: .system(.continuousVolume)
      )
    )
    XCTAssertFalse(
      TrackpadMatchDispatchPolicy.shouldDispatch(
        continuousMatch,
        edgeGestureOwned: hoverDecision.isSuppressing
      ),
      "a hover-derived non-owner must not dispatch continuous edge work"
    )

    XCTAssertFalse(
      policy.consume(
        frame: frame(2, 0.01, [
          contact(1, .touch, 0.07, 0.60),
          contact(2, .touch, 0.05, 0.62),
        ]),
        settings: settings,
        context: edgeContext
      ).isSuppressing,
      "a hover-tainted frame must remain fail-open while its contacts are still down"
    )

    _ = policy.consume(
      frame: frame(3, 0.02, [
        contact(1, .out, 0.07, 0.60),
        contact(2, .out, 0.05, 0.62),
      ]),
      settings: settings,
      context: edgeContext
    )
    XCTAssertTrue(
      policy.consume(
        frame: frame(4, 0.03, [
          contact(3, .touch, 0.07, 0.50),
          contact(4, .touch, 0.05, 0.52),
        ]),
        settings: settings,
        context: edgeContext
      ).isSuppressing,
      "a fresh pair may own scrolling only after every hover-tainted contact lifted"
    )
  }

  func testContinuousDispatchRequiresCurrentEdgeOwnerWithoutBlockingOtherGestures() {
    let continuousMatch = gestureMatch(
      TrackpadGestureRule(
        name: "Continuous edge",
        trigger: TrackpadGestureTrigger(
          kind: .edgeContinuous,
          fingerCount: 2,
          edge: .left,
          minimumDistance: 0.02
        ),
        action: .system(.continuousVolume)
      )
    )
    let discreteMatch = gestureMatch(
      TrackpadGestureRule(
        name: "One-finger tap",
        trigger: TrackpadGestureTrigger(
          kind: .contact,
          fingerCount: 1,
          contactGesture: .tap
        ),
        action: .system(.volumeUp)
      )
    )

    XCTAssertFalse(
      TrackpadMatchDispatchPolicy.shouldDispatch(continuousMatch, edgeGestureOwned: false),
      "a blocked edge suppression policy must not dispatch edge-continuous work"
    )
    XCTAssertTrue(
      TrackpadMatchDispatchPolicy.shouldDispatch(continuousMatch, edgeGestureOwned: true),
      "the current edge owner may dispatch its continuous match"
    )
    XCTAssertTrue(
      TrackpadMatchDispatchPolicy.shouldDispatch(discreteMatch, edgeGestureOwned: false),
      "edge ownership must not suppress unrelated discrete gestures"
    )
  }

  func testMomentumDrainSurvivesInactiveFramesUntilItsDeadline() {
    var policy = TrackpadMomentumDrainPolicy()
    let changedPhase = Int64(NSEvent.Phase.changed.rawValue)

    policy.update(active: false, startsDrain: true, now: 10, duration: 1)
    for now in [10.2, 10.8] {
      policy.update(active: false, startsDrain: false, now: now, duration: 1)
      XCTAssertTrue(
        policy.shouldSuppress(
          momentumPhase: changedPhase,
          scrollPhase: changedPhase,
          now: now
        ),
        "an inactive raw frame must not clear an already-started drain"
      )
    }

    XCTAssertFalse(
      policy.shouldSuppress(
        momentumPhase: changedPhase,
        scrollPhase: changedPhase,
        now: 11.01
      ),
      "drain must end at its bounded deadline"
    )
  }

  func testMomentumDrainEndsForANewOwnerOrExplicitCancellation() {
    var policy = TrackpadMomentumDrainPolicy()
    let changedPhase = Int64(NSEvent.Phase.changed.rawValue)

    policy.update(active: false, startsDrain: true, now: 20, duration: 1)
    policy.update(active: true, startsDrain: false, now: 20.1, duration: 1)
    XCTAssertFalse(
      policy.shouldSuppress(
        momentumPhase: changedPhase,
        scrollPhase: changedPhase,
        now: 20.2
      ),
      "a new edge owner must replace the old drain window"
    )

    policy.update(active: false, startsDrain: true, now: 30, duration: 1)
    policy.cancel()
    XCTAssertFalse(
      policy.shouldSuppress(
        momentumPhase: changedPhase,
        scrollPhase: changedPhase,
        now: 30.1
      ),
      "explicit cancellation must remove the pending drain"
    )
  }

  private let edgeContext = TrackpadGestureContext(
    bundleIdentifier: "com.example.editor",
    modifiers: []
  )

  private func edgeSuppressionSettings() -> TrackpadGestureSettings {
    TrackpadGestureSettings(
      isEnabled: true,
      edgeWidth: 0.08,
      sensitivity: 1,
      rules: [
        TrackpadGestureRule(
          name: "Left edge volume",
          trigger: TrackpadGestureTrigger(
            kind: .edgeContinuous,
            fingerCount: 2,
            edge: .left,
            minimumDistance: 0.02
          ),
          action: .system(.continuousVolume)
        ),
      ]
    )
  }

  private func gestureMatch(_ rule: TrackpadGestureRule) -> TrackpadGestureMatch {
    TrackpadGestureMatch(
      id: 1,
      rule: rule,
      direction: nil,
      continuousDelta: 0,
      timestamp: 0
    )
  }

  private func frame(
    _ number: Int32,
    _ timestamp: TimeInterval,
    _ contacts: [TrackpadContact]
  ) -> TrackpadFrame {
    TrackpadFrame(
      deviceID: 1,
      isBuiltIn: true,
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

final class PowerHelperRegistrationPolicySafetyTests: XCTestCase {
  func testEnabledAutomaticRegistrationInspectsInsteadOfRegisteringAgain() {
    XCTAssertEqual(
      PowerHelperRegistrationPolicy.requestAction(serviceIsEnabled: true),
      .inspectCurrentRegistration,
      "an enabled Helper with a separately detected stale build must route to explicit refresh, not re-register automatically"
    )
  }

  func testSuccessfulRegistrationClearsAStaleRefreshRequirement() {
    XCTAssertFalse(
      PowerHelperRegistrationPolicy.refreshRequired(
        previousValue: true,
        registrationSucceeded: true
      ),
      "a successful register must converge a stale refresh flag"
    )
  }

  func testFailedRegistrationAfterUnregisterStaysOnTheDirectInstallRetryPath() {
    XCTAssertFalse(
      PowerHelperRegistrationPolicy.refreshRequired(
        previousValue: false,
        registrationSucceeded: false
      ),
      "after unregister succeeded, a failed register must allow Install to retry without another refresh cycle"
    )
  }

  func testRemovalRefusesANonApplicationsBundleEvenWhenTheHelperIsPackaged() {
    XCTAssertFalse(
      PowerHelperRegistrationPolicy.canRemoveHelper(
        bundleURL: URL(fileURLWithPath: "/Users/tester/Downloads/MenuCue.app"),
        packagedHelperAvailable: true
      ),
      "removal must fail closed outside /Applications rather than invoking SMAppService"
    )
  }
}
