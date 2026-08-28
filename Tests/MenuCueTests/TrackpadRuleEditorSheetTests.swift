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

  func testTipTapBadgesNameTheFamilyAndTheAnchorFinger() {
    let trigger = TrackpadGestureTrigger(
      kind: .tipTap,
      fingerCount: 2,
      selectedFingerIndex: 1,
      tapSpacing: .normal
    )

    let badges = TrackpadRuleSummary.triggerBadges(for: trigger)

    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(badges[0], L10n.string("Tip-tap"))
    XCTAssertTrue(
      badges[1].contains("2"),
      "the badge has to name the anchor finger: \(badges[1])"
    )
    XCTAssertTrue(badges[1].contains(L10n.string("Normal")), badges[1])
  }

  func testContinuousEdgeBadgesNameTheFamilyAndTheEdge() {
    let trigger = TrackpadGestureTrigger(kind: .edgeContinuous, fingerCount: 2, edge: .right)

    let badges = TrackpadRuleSummary.triggerBadges(for: trigger)

    XCTAssertEqual(badges.count, 2)
    XCTAssertEqual(badges[0], L10n.string("Continuous Edge"))
    XCTAssertTrue(badges[1].contains(L10n.string("Right")), badges[1])
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

  // MARK: - Helpers

  private func rule(named name: String) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: name,
      trigger: TrackpadGestureTrigger(kind: .contact, fingerCount: 2),
      action: .system(.volumeUp)
    )
  }
}
