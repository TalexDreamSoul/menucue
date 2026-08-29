import XCTest

@testable import MenuCue

/// The rule editor became a sheet over a draft copy, which moved two decisions out of the
/// view and into functions worth testing: where a saved draft lands in the rule list, and
/// what a row says about a trigger it only has one line for.
final class TrackpadRuleEditorSheetTests: XCTestCase {

  // MARK: - Draft commit

  func testSavingANewRuleAppendsItToTheEndOfTheList() {
    let existing = [rule(named: "First"), rule(named: "Second")]
    let addition = rule(named: "Third")

    let result = TrackpadRuleDraft.upserting(addition, into: existing)

    XCTAssertEqual(result.map(\.name), ["First", "Second", "Third"])
    XCTAssertEqual(result.last?.id, addition.id)
  }

  func testSavingAnEditedRuleReplacesItWithoutMovingIt() {
    let middle = rule(named: "Second")
    let existing = [rule(named: "First"), middle, rule(named: "Third")]
    var edited = middle
    edited.name = "Renamed"
    edited.isEnabled = false

    let result = TrackpadRuleDraft.upserting(edited, into: existing)

    XCTAssertEqual(result.map(\.name), ["First", "Renamed", "Third"])
    XCTAssertEqual(result.count, existing.count, "an edit must not add a second copy")
    XCTAssertEqual(result[1].id, middle.id, "the rule keeps its identity across an edit")
    XCTAssertEqual(result[1].isEnabled, false)
  }

  /// A rule deleted from another surface while its sheet was open would otherwise be
  /// resurrected in place; appending is the honest outcome, and it is also what makes the
  /// same function serve the new-rule path.
  func testSavingARuleWhoseIDIsGoneAppendsItRatherThanFailing() {
    let existing = [rule(named: "First")]
    let orphan = rule(named: "Removed")

    let result = TrackpadRuleDraft.upserting(orphan, into: existing)

    XCTAssertEqual(result.map(\.name), ["First", "Removed"])
  }

  func testUpsertingLeavesTheUntouchedRulesExactlyAsTheyWere() {
    let untouched = rule(named: "First")
    let target = rule(named: "Second")
    var edited = target
    edited.name = "Renamed"

    let result = TrackpadRuleDraft.upserting(edited, into: [untouched, target])

    XCTAssertEqual(result.first, untouched)
  }

  // MARK: - Trigger badges

  func testTipTapBadgesNameTheTapAndLeaveADefaultSpacingOut() {
    let trigger = TrackpadGestureTrigger(
      kind: .tipTap,
      fingerCount: 2,
      selectedFingerIndex: 1,
      tapSpacing: .normal
    )

    let badges = TrackpadRuleSummary.triggerBadges(for: trigger)

    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(badges[0], L10n.string("Tip-tap"))
    XCTAssertEqual(badges[1], L10n.format("Finger %d taps", 2))
    XCTAssertFalse(
      badges[1].contains(L10n.string("Normal")),
      "a tolerance the user never moved is not worth a word: \(badges[1])"
    )
  }

  /// A spacing the user did choose is the only thing separating two otherwise identical
  /// tip-tap rules, so leaving out the default must not leave out the rest.
  func testTipTapBadgesKeepASpacingTheUserChose() {
    let trigger = TrackpadGestureTrigger(
      kind: .tipTap,
      fingerCount: 2,
      selectedFingerIndex: 0,
      tapSpacing: .far
    )

    let badges = TrackpadRuleSummary.triggerBadges(for: trigger)

    XCTAssertEqual(badges[1], L10n.format("Finger %d taps · %@", 1, L10n.string("Far")))
  }

  /// The badge used to borrow the direction words, so a rule watching the left corridor
  /// read as a swipe to the left.
  func testContinuousEdgeBadgesNameTheEdgeRatherThanADirection() {
    let trigger = TrackpadGestureTrigger(kind: .edgeContinuous, fingerCount: 2, edge: .right)

    let badges = TrackpadRuleSummary.triggerBadges(for: trigger)

    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(badges[0], L10n.string("Continuous Edge"))
    XCTAssertEqual(badges[1], L10n.format("%d fingers · %@", 2, L10n.string("Right edge")))
  }

  /// The four rules that ship enabled are the first thing a new user reads.
  func testShippedPresetBadgesReadAsGesturesRatherThanStoredValues() {
    let badges = TrackpadGestureSettings.presetRules.map {
      TrackpadRuleSummary.triggerBadges(for: $0.trigger)[1]
    }

    XCTAssertEqual(badges, [
      L10n.format("Finger %d taps", 1),
      L10n.format("Finger %d taps", 2),
      L10n.format("%d fingers · %@", 2, L10n.string("Left edge")),
      L10n.format("%d fingers · %@", 2, L10n.string("Right edge")),
      L10n.format(
        "%1$d fingers · Finger %2$d %3$@", 2, 1, L10n.string("up and down")),
    ])
  }

  /// Which finger does the sliding and which way it goes are the only things separating two
  /// anchored-slide rules, so a badge that dropped either would leave two rows reading alike.
  func testAnchoredSlideBadgesNameTheSlidingFingerAndItsAxis() {
    let leftVertical = TrackpadGestureTrigger(
      kind: .anchoredSlide,
      fingerCount: 2,
      selectedFingerIndex: 0,
      slideAxis: .vertical
    )
    let rightHorizontal = TrackpadGestureTrigger(
      kind: .anchoredSlide,
      fingerCount: 2,
      selectedFingerIndex: 1,
      slideAxis: .horizontal
    )

    let badges = TrackpadRuleSummary.triggerBadges(for: leftVertical)

    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(badges[0], L10n.string("Anchored Slide"))
    XCTAssertEqual(
      badges[1],
      L10n.format("%1$d fingers · Finger %2$d %3$@", 2, 1, L10n.string("up and down"))
    )
    XCTAssertNotEqual(badges[1], TrackpadRuleSummary.triggerBadges(for: rightHorizontal)[1])
  }

  func testSwipeBadgesNameTheFamilyAndTheDirection() {
    let trigger = TrackpadGestureTrigger(kind: .swipe, fingerCount: 3, direction: .up)

    let badges = TrackpadRuleSummary.triggerBadges(for: trigger)

    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(badges[0], L10n.string("Swipe"))
    XCTAssertTrue(badges[1].contains("3"), badges[1])
    XCTAssertTrue(badges[1].contains(L10n.string("Up")), badges[1])
  }

  /// The badges are the only thing separating two rows of the same family, so two rules
  /// that differ in their key parameter cannot read the same.
  func testSiblingsOfTheSameFamilyGetDistinctBadges() {
    let left = TrackpadGestureTrigger(kind: .edgeContinuous, fingerCount: 2, edge: .left)
    let right = TrackpadGestureTrigger(kind: .edgeContinuous, fingerCount: 2, edge: .right)

    XCTAssertEqual(
      TrackpadRuleSummary.triggerBadges(for: left).first,
      TrackpadRuleSummary.triggerBadges(for: right).first
    )
    XCTAssertNotEqual(
      TrackpadRuleSummary.triggerBadges(for: left).last,
      TrackpadRuleSummary.triggerBadges(for: right).last
    )
  }

  func testEveryGestureFamilyProducesTwoNonEmptyBadges() {
    for kind in TrackpadGestureKind.allCases {
      let badges = TrackpadRuleSummary.triggerBadges(
        for: TrackpadGestureTrigger(kind: kind, fingerCount: 2)
      )
      XCTAssertEqual(badges.count, 2, "\(kind) must still summarize in two badges")
      XCTAssertFalse(badges.contains(where: \.isEmpty), "\(kind) produced an empty badge")
    }
  }

  // MARK: - Advanced disclosure

  /// The whole point of folding: a rule nobody has tuned opens as the few choices that
  /// define it. This is the draft "Add Rule" seeds, field for field.
  func testAFreshDraftOpensWithBothAdvancedGroupsFolded() {
    let draft = TrackpadGestureRule(
      name: "Gesture Rule 1",
      trigger: TrackpadGestureTrigger(kind: .contact),
      action: TrackpadGestureAction(kind: .none)
    )

    XCTAssertFalse(TrackpadRuleAdvancedDisclosure.expandsTrigger(for: draft))
    XCTAssertFalse(TrackpadRuleAdvancedDisclosure.expandsScope(for: draft))
  }

  func testEveryGestureFamilyStartsFoldedAtItsOwnDefaults() {
    for kind in TrackpadGestureKind.allCases {
      let untouched = TrackpadGestureRule(
        name: "Untouched",
        trigger: TrackpadGestureTrigger(kind: kind),
        action: .system(.volumeUp)
      )

      XCTAssertFalse(
        TrackpadRuleAdvancedDisclosure.expandsTrigger(for: untouched),
        "\(kind) opened its advanced group with nothing in it to show")
    }
  }

  /// Folding a value the user chose would make a tuned rule read exactly like an untouched
  /// one, and the difference would only surface as a gesture behaving oddly.
  func testAThresholdTheUserMovedOpensTheTriggerGroup() {
    var tuned = rule(named: "Slow tap")
    tuned.trigger.maximumDuration = 1.2

    XCTAssertTrue(TrackpadRuleAdvancedDisclosure.expandsTrigger(for: tuned))
  }

  func testARequiredModifierOpensTheTriggerGroup() {
    var guarded = rule(named: "Command tap")
    guarded.requiredModifiers = [.command]

    XCTAssertTrue(TrackpadRuleAdvancedDisclosure.expandsTrigger(for: guarded))
  }

  /// A swipe velocity stored on a contact rule is not a setting that rule has: the contact
  /// family never shows one, so opening the group would present an empty explanation.
  func testAThresholdThisFamilyNeverShowsLeavesTheGroupFolded() {
    var contact = rule(named: "Two-finger tap")
    contact.trigger.minimumVelocity = 4

    XCTAssertTrue(
      TrackpadRuleAdvancedDisclosure.foldedTuning(for: .swipe).contains(.minimumVelocity),
      "a swipe does fold its velocity away, so this rule is about the family, not the field")
    XCTAssertFalse(TrackpadRuleAdvancedDisclosure.expandsTrigger(for: contact))
  }

  func testTheScopeGroupOpensForAnythingTheUserSetInIt() {
    var deviceLimited = rule(named: "Built-in only")
    deviceLimited.deviceScope = .builtInOnly
    var activating = rule(named: "Follows the pointer")
    activating.activatesWindowUnderPointer = true
    var annotated = rule(named: "Explained")
    annotated.note = "Only for the review build."

    XCTAssertTrue(TrackpadRuleAdvancedDisclosure.expandsScope(for: deviceLimited))
    XCTAssertTrue(TrackpadRuleAdvancedDisclosure.expandsScope(for: activating))
    XCTAssertTrue(TrackpadRuleAdvancedDisclosure.expandsScope(for: annotated))
  }

  /// Whitespace is not a note, and a group that opens on it opens on every rule whose
  /// editor was clicked into once.
  func testAnEmptyNoteLeavesTheScopeGroupFolded() {
    var blank = rule(named: "Blank note")
    blank.note = "  \n "

    XCTAssertFalse(TrackpadRuleAdvancedDisclosure.expandsScope(for: blank))
  }

  /// The presets ship tuned — hold times and step distances chosen against real hardware.
  /// A user reading one of them must see the values it actually runs on.
  func testShippedPresetsShowTheTuningTheyShipWith() {
    for preset in TrackpadGestureSettings.presetRules {
      XCTAssertTrue(
        TrackpadRuleAdvancedDisclosure.expandsTrigger(for: preset),
        "\(preset.name) hides the thresholds it was shipped with")
    }
  }

  // MARK: - Helpers

  private func rule(named name: String) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: name,
      trigger: TrackpadGestureTrigger(kind: .contact, fingerCount: 2),
      action: .system(.volumeUp)
    )
  }
}
