import Foundation
import XCTest

@testable import MenuCue

final class TrackpadClickSuppressionPolicyTests: XCTestCase {
  func testShouldArmRequiresMatchingEnabledScopedContactTapRule() {
    let policy = TrackpadClickSuppressionPolicy()
    let candidate = frame(
      1,
      0,
      contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
    )
    let matchingContext = TrackpadGestureContext(
      bundleIdentifier: "com.example.editor",
      modifiers: [.option]
    )
    let matchingSettings = tapSettings(rules: [matchingContactTapRule()])

    XCTAssertTrue(policy.shouldArm(frame: candidate, settings: matchingSettings, context: matchingContext))
    XCTAssertFalse(
      policy.shouldArm(
        frame: candidate,
        settings: matchingSettings,
        context: TrackpadGestureContext(bundleIdentifier: "com.example.other", modifiers: [.option])
      )
    )
    XCTAssertFalse(
      policy.shouldArm(
        frame: candidate,
        settings: matchingSettings,
        context: TrackpadGestureContext(bundleIdentifier: "com.example.editor")
      )
    )

    let disabledSettings = tapSettings(rules: [matchingContactTapRule(isEnabled: false)])
    XCTAssertFalse(policy.shouldArm(frame: candidate, settings: disabledSettings, context: matchingContext))

    var nonContactRule = matchingContactTapRule()
    nonContactRule.trigger.kind = .tipTap
    let nonContactSettings = tapSettings(rules: [nonContactRule])
    XCTAssertFalse(policy.shouldArm(frame: candidate, settings: nonContactSettings, context: matchingContext))
  }

  func testMatchingCandidateArmsThenCompletesOnlyWhenItsContactsEnd() {
    var policy = TrackpadClickSuppressionPolicy()
    let settings = tapSettings(rules: [matchingContactTapRule()])
    let context = TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option])
    let active = frame(
      1,
      0,
      contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
    )

    XCTAssertEqual(consume(&policy, frame: active, settings: settings, context: context), .arm)
    XCTAssertEqual(
      consume(
        &policy,
        frame: frame(
          2,
          0.05,
          contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
        ),
        settings: settings,
        context: context
      ),
      .none
    )
    XCTAssertEqual(
      consume(
        &policy,
        frame: frame(
          3,
          0.10,
          contacts: [contact(1, .out, 0.30, 0.50), contact(2, .out, 0.70, 0.50)]
        ),
        settings: settings,
        context: context
      ),
      .complete
    )
  }

  func testNewUnrelatedContactCancelsTentativeSuppressionBeforeItCanBeConfirmed() {
    var policy = TrackpadClickSuppressionPolicy()
    let settings = tapSettings(rules: [matchingContactTapRule()])
    let context = TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option])

    XCTAssertEqual(
      consume(
        &policy,
        frame: frame(
          1,
          0,
          contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
        ),
        settings: settings,
        context: context
      ),
      .arm
    )
    XCTAssertEqual(
      consume(
        &policy,
        frame: frame(2, 0.05, contacts: [contact(9, .touch, 0.50, 0.50)]),
        settings: settings,
        context: context
      ),
      .cancel
    )
    XCTAssertEqual(
      consume(
        &policy,
        frame: frame(3, 0.10, contacts: [contact(9, .out, 0.50, 0.50)]),
        settings: settings,
        context: context
      ),
      .none
    )
  }

  func testCandidateTimeoutAndRuleLossCancelTentativeSuppression() {
    let settings = tapSettings(rules: [matchingContactTapRule()])
    let context = TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option])
    let active = frame(
      1,
      0,
      contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
    )

    var timedOutPolicy = TrackpadClickSuppressionPolicy()
    XCTAssertEqual(consume(&timedOutPolicy, frame: active, settings: settings, context: context), .arm)
    XCTAssertEqual(
      consume(
        &timedOutPolicy,
        frame: frame(2, 0.181, contacts: active.contacts),
        settings: settings,
        context: context
      ),
      .cancel
    )

    var ruleLossPolicy = TrackpadClickSuppressionPolicy()
    XCTAssertEqual(consume(&ruleLossPolicy, frame: active, settings: settings, context: context), .arm)
    var disabledRuleSettings = settings
    disabledRuleSettings.rules[0].isEnabled = false
    XCTAssertEqual(
      consume(
        &ruleLossPolicy,
        frame: frame(2, 0.05, contacts: active.contacts),
        settings: disabledRuleSettings,
        context: context
      ),
      .cancel
    )
  }

  func testNonmatchingAndDuplicateContactsNeverCreateSuppressionCandidates() {
    let context = TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option])
    let active = frame(
      1,
      0,
      contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
    )

    var nonMatchingPolicy = TrackpadClickSuppressionPolicy()
    var nonTapRule = matchingContactTapRule()
    nonTapRule.trigger.kind = .edgeContinuous
    let nonMatchingSettings = tapSettings(rules: [nonTapRule])

    XCTAssertFalse(nonMatchingPolicy.shouldArm(frame: active, settings: nonMatchingSettings, context: context))
    XCTAssertEqual(
      consume(&nonMatchingPolicy, frame: active, settings: nonMatchingSettings, context: context),
      .none
    )

    var duplicatePolicy = TrackpadClickSuppressionPolicy()
    let duplicate = frame(
      1,
      0,
      contacts: [contact(7, .touch, 0.30, 0.50), contact(7, .touch, 0.70, 0.50)]
    )
    let matchingSettings = tapSettings(rules: [matchingContactTapRule()])

    XCTAssertFalse(duplicatePolicy.shouldArm(frame: duplicate, settings: matchingSettings, context: context))
    XCTAssertEqual(
      consume(&duplicatePolicy, frame: duplicate, settings: matchingSettings, context: context),
      .none
    )
    XCTAssertEqual(
      consume(
        &duplicatePolicy,
        frame: frame(2, 0.01, contacts: [contact(7, .out, 0.30, 0.50)]),
        settings: matchingSettings,
        context: context
      ),
      .none
    )
  }

  func testDisablingAnArmedCandidateCancelsAndAllowsANewCandidateAfterReenablement() {
    var policy = TrackpadClickSuppressionPolicy()
    let enabledSettings = tapSettings(rules: [matchingContactTapRule()])
    var disabledSettings = enabledSettings
    disabledSettings.suppressesClickAfterMultiFingerTap = false
    let context = TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option])
    let active = frame(
      1,
      0,
      contacts: [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]
    )

    XCTAssertEqual(consume(&policy, frame: active, settings: enabledSettings, context: context), .arm)
    XCTAssertEqual(consume(&policy, frame: active, settings: disabledSettings, context: context), .cancel)
    XCTAssertEqual(
      consume(
        &policy,
        frame: frame(2, 0.02, contacts: active.contacts),
        settings: enabledSettings,
        context: context
      ),
      .arm
    )
  }

  func testDeviceAndGlobalResetsMakeFreshCandidatesWithoutDisturbingOtherDevices() {
    var policy = TrackpadClickSuppressionPolicy()
    let settings = tapSettings(rules: [matchingContactTapRule()])
    let context = TrackpadGestureContext(bundleIdentifier: "com.example.editor", modifiers: [.option])
    let contacts = [contact(1, .touch, 0.30, 0.50), contact(2, .touch, 0.70, 0.50)]

    XCTAssertEqual(
      consume(&policy, frame: frame(1, 0, contacts: contacts, deviceID: 1), settings: settings, context: context),
      .arm
    )
    XCTAssertEqual(
      consume(&policy, frame: frame(1, 0, contacts: contacts, deviceID: 2), settings: settings, context: context),
      .arm
    )

    policy.reset(deviceID: 1)

    XCTAssertEqual(
      consume(&policy, frame: frame(2, 0.01, contacts: contacts, deviceID: 1), settings: settings, context: context),
      .arm
    )
    XCTAssertEqual(
      consume(&policy, frame: frame(2, 0.01, contacts: contacts, deviceID: 2), settings: settings, context: context),
      .none
    )

    policy.reset()

    XCTAssertEqual(
      consume(&policy, frame: frame(3, 0.02, contacts: contacts, deviceID: 1), settings: settings, context: context),
      .arm
    )
    XCTAssertEqual(
      consume(&policy, frame: frame(3, 0.02, contacts: contacts, deviceID: 2), settings: settings, context: context),
      .arm
    )
  }

  private func tapSettings(rules: [TrackpadGestureRule]) -> TrackpadGestureSettings {
    TrackpadGestureSettings(
      isEnabled: true,
      suppressesClickAfterMultiFingerTap: true,
      rules: rules
    )
  }

  private func matchingContactTapRule(isEnabled: Bool = true) -> TrackpadGestureRule {
    TrackpadGestureRule(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Editor Option two-finger tap",
      isEnabled: isEnabled,
      requiredModifiers: [.option],
      applicationScope: TrackpadApplicationScope(
        mode: .includedApplications,
        applications: [TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")]
      ),
      deviceScope: .builtInOnly,
      trigger: TrackpadGestureTrigger(
        kind: .contact,
        fingerCount: 2,
        contactGesture: .tap,
        maximumDuration: 0.5,
        movementTolerance: 0.035
      ),
      action: .system(.volumeUp)
    )
  }

  private func consume(
    _ policy: inout TrackpadClickSuppressionPolicy,
    frame: TrackpadFrame,
    settings: TrackpadGestureSettings,
    context: TrackpadGestureContext
  ) -> TrackpadClickSuppressionDirective {
    let shouldArm = policy.shouldArm(frame: frame, settings: settings, context: context)
    return policy.consume(
      frame: frame,
      isEnabled: settings.suppressesClickAfterMultiFingerTap,
      shouldArm: shouldArm
    )
  }

  private func frame(
    _ frameNumber: Int32,
    _ timestamp: TimeInterval,
    contacts: [TrackpadContact],
    deviceID: UInt64 = 1
  ) -> TrackpadFrame {
    TrackpadFrame(
      deviceID: deviceID,
      isBuiltIn: true,
      timestamp: timestamp,
      frameNumber: frameNumber,
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
