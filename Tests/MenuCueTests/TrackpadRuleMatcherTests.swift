import Foundation
import XCTest

@testable import MenuCue

/// The engine and the two input-suppression policies each used to carry their own copy of
/// the rule predicate and the corridor/region math. These tests keep the surviving shared
/// implementation pinned to the behaviour those copies had, and lock in the ordering the
/// suppression copies were missing.
final class TrackpadRuleMatcherTests: XCTestCase {
  private let editorScope = TrackpadApplicationScope(
    mode: .includedApplications,
    applications: [
      TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")
    ]
  )

  // MARK: - Predicate parity with the retired copies

  func testEligibilityMatchesTheRetiredEnginePredicateAcrossEveryScopeCombination() {
    for rule in scopeMatrixRules() {
      for context in contextMatrix() {
        XCTAssertEqual(
          TrackpadRuleMatcher.matches(rule, context: context),
          legacyEnginePredicate(rule, context: context),
          "rule \(rule.name) in \(context)"
        )
      }
    }
  }

  func testEligibleRulesReturnsEveryRuleTheRetiredPredicateAccepted() {
    let rules = scopeMatrixRules()
    for context in contextMatrix() {
      let eligible = TrackpadRuleMatcher.eligibleRules(rules, context: context)
      let expected = rules.filter { legacyEnginePredicate($0, context: context) }
      XCTAssertEqual(
        Set(eligible.map(\.id)),
        Set(expected.map(\.id)),
        "eligible set must not drift from the retired predicate in \(context)"
      )
    }
  }

  func testEligibleRulesPreservesTheEngineSpecificityOrdering() {
    let context = TrackpadRuleContext(
      bundleIdentifier: "com.example.editor",
      modifiers: [],
      isBuiltIn: true
    )
    let rules = [
      rule(name: "all first", scope: .all),
      rule(name: "editor first", scope: editorScope),
      rule(name: "all second", scope: .all),
      rule(name: "editor second", scope: editorScope),
    ]

    let ordered = TrackpadRuleMatcher.eligibleRules(rules, context: context)

    XCTAssertEqual(
      ordered.map(\.name),
      ["editor first", "editor second", "all first", "all second"],
      "application-scoped rules outrank all-application rules, configuration order breaks ties"
    )
    XCTAssertEqual(ordered.map(\.name), legacyEngineEligibleRules(rules, context: context).map(\.name))
  }

  func testCustomPredicateNarrowsTheResultWithoutDisturbingTheOrdering() {
    let context = TrackpadRuleContext(
      bundleIdentifier: "com.example.editor",
      modifiers: [],
      isBuiltIn: true
    )
    let rules = [
      rule(name: "all swipe", scope: .all, kind: .swipe),
      rule(name: "editor contact", scope: editorScope, kind: .contact),
      rule(name: "all contact", scope: .all, kind: .contact),
    ]

    let contacts = TrackpadRuleMatcher.eligibleRules(rules, context: context) {
      $0.trigger.kind == .contact
    }

    XCTAssertEqual(contacts.map(\.name), ["editor contact", "all contact"])
  }

  // MARK: - Specificity in the suppression paths

  func testClickSuppressionArmsForTheSameRulesTheRetiredPredicateAccepted() {
    let policy = TrackpadClickSuppressionPolicy()
    let frameContacts = [
      TrackpadContact(id: 1, state: .touch, position: TrackpadPoint(x: 0.20, y: 0.20)),
      TrackpadContact(id: 2, state: .touch, position: TrackpadPoint(x: 0.24, y: 0.24)),
    ]

    for region in TrackpadGestureRegion.allCases {
      for context in contextMatrix() {
        var tapRule = rule(name: "tap \(region.rawValue)", scope: .all, kind: .contact)
        tapRule.trigger.region = region
        tapRule.trigger.fingerCount = 2
        tapRule.requiredModifiers = context.modifiers
        let settings = settings(rules: [tapRule])
        let frame = frame(contacts: frameContacts, isBuiltIn: context.isBuiltIn)

        XCTAssertEqual(
          policy.shouldArm(
            frame: frame,
            settings: settings,
            context: TrackpadGestureContext(
              bundleIdentifier: context.bundleIdentifier,
              modifiers: context.modifiers
            )
          ),
          legacyShouldArm(
            frame: frame,
            settings: settings,
            bundleIdentifier: context.bundleIdentifier,
            modifiers: context.modifiers
          ),
          "region \(region.rawValue) in \(context)"
        )
      }
    }
  }

  func testClickSuppressionStillArmsWhenOnlyTheLeastSpecificRuleMatches() {
    let policy = TrackpadClickSuppressionPolicy()
    var scoped = rule(name: "editor tap", scope: editorScope, kind: .contact)
    scoped.trigger.fingerCount = 3
    var broad = rule(name: "all tap", scope: .all, kind: .contact)
    broad.trigger.fingerCount = 2

    let armed = policy.shouldArm(
      frame: frame(contacts: [
        TrackpadContact(id: 1, state: .touch, position: TrackpadPoint(x: 0.50, y: 0.50)),
        TrackpadContact(id: 2, state: .touch, position: TrackpadPoint(x: 0.54, y: 0.52)),
      ]),
      settings: settings(rules: [scoped, broad]),
      context: TrackpadGestureContext(bundleIdentifier: "com.example.editor")
    )

    XCTAssertTrue(armed, "ordering the candidates must not drop a lower-specificity match")
  }

  func testEdgeSuppressionKeepsALowSpecificityMatchAheadOfAHigherScopedMiss() {
    // The higher-specificity rule sorts first but guards the opposite edge, so ordering
    // the candidates must not shadow the all-applications rule the fingers actually match.
    let settings = settings(
      rules: [
        edgeRule(name: "editor right", scope: editorScope, edge: .right),
        edgeRule(name: "all left", scope: .all, edge: .left),
      ]
    )

    var policy = TrackpadEdgeScrollSuppressionPolicy()
    _ = policy.consume(
      frame: frame(contacts: [
        TrackpadContact(id: 1, state: .touch, position: TrackpadPoint(x: 0.05, y: 0.50))
      ]),
      settings: settings,
      context: TrackpadGestureContext(bundleIdentifier: "com.example.editor")
    )
    let decision = policy.consume(
      frame: frame(contacts: [
        TrackpadContact(id: 1, state: .touch, position: TrackpadPoint(x: 0.05, y: 0.50)),
        TrackpadContact(id: 2, state: .touch, position: TrackpadPoint(x: 0.03, y: 0.52)),
      ]),
      settings: settings,
      context: TrackpadGestureContext(bundleIdentifier: "com.example.editor")
    )

    XCTAssertTrue(
      decision.isSuppressing,
      "specificity ordering must not drop the lower-ranked rule the corridor actually matched"
    )
  }

  // MARK: - Geometry parity with the retired copies

  func testRegionMatchingIsIdenticalToTheRetiredCopyOverTheWholePad() {
    for region in TrackpadGestureRegion.allCases {
      for point in samplePoints() {
        XCTAssertEqual(
          TrackpadGeometry.regionMatches(region, point: point),
          legacyRegionMatches(region, point: point),
          "\(region.rawValue) at (\(point.x), \(point.y))"
        )
      }
    }
  }

  func testEdgeContainmentIsIdenticalToTheRetiredCopyForEveryEdgeAndWidth() {
    for edge in TrackpadEdge.allCases {
      for width in [0.03, 0.08, 0.2, 0.35] {
        for point in samplePoints() {
          XCTAssertEqual(
            TrackpadGeometry.edgeContains(edge, point: point, width: width),
            legacyEdgeContains(edge, point: point, width: width),
            "\(edge.rawValue) width \(width) at (\(point.x), \(point.y))"
          )
        }
      }
    }
  }

  func testCentroidIsIdenticalToBothRetiredCopies() {
    let samples: [[TrackpadPoint]] = [
      [],
      [TrackpadPoint(x: 0.25, y: 0.75)],
      [TrackpadPoint(x: 0.02, y: 0.50), TrackpadPoint(x: 0.04, y: 0.52)],
      [
        TrackpadPoint(x: 0.10, y: 0.20),
        TrackpadPoint(x: 0.30, y: 0.40),
        TrackpadPoint(x: 0.70, y: 0.90),
      ],
    ]

    for points in samples {
      let centroid = TrackpadGeometry.centroid(points)
      XCTAssertEqual(centroid, legacyEngineCentroid(points))
      XCTAssertEqual(centroid, legacyPolicyCentroid(points))
    }
  }

  func testExpandedCorridorMatchesTheRetiredWideningAndClamp() {
    for width in [0.03, 0.08, 0.2, 0.3, 0.4] {
      XCTAssertEqual(
        TrackpadGeometry.edgeCorridorWidth(width, expanded: true),
        min(0.35, width + 0.06),
        accuracy: 0.000_001
      )
      XCTAssertEqual(
        TrackpadGeometry.edgeCorridorWidth(width),
        min(0.35, width),
        accuracy: 0.000_001
      )
    }
  }

  // MARK: - Retired implementations, kept verbatim as the oracle
  //
  // Copied unchanged from TrackpadGestureEngine and TrackpadGestureService as they stood at
  // c79aca8, the commit before the matcher was extracted. Nothing production reads these;
  // they exist so the shared implementation is diffed against the behaviour it replaced
  // rather than against itself. Do not "fix" them to agree with TrackpadGeometry.

  private func legacyEnginePredicate(
    _ rule: TrackpadGestureRule,
    context: TrackpadRuleContext
  ) -> Bool {
    guard rule.isEnabled,
      rule.applicationScope.matches(bundleIdentifier: context.bundleIdentifier),
      rule.requiredModifiers == context.modifiers
    else { return false }
    switch rule.deviceScope {
    case .allSupported: return true
    case .builtInOnly: return context.isBuiltIn
    case .externalOnly: return !context.isBuiltIn
    }
  }

  private func legacyEngineEligibleRules(
    _ rules: [TrackpadGestureRule],
    context: TrackpadRuleContext
  ) -> [TrackpadGestureRule] {
    rules.enumerated().filter { _, rule in
      legacyEnginePredicate(rule, context: context)
    }.sorted { lhs, rhs in
      let leftSpecificity = lhs.element.applicationScope.specificity
      let rightSpecificity = rhs.element.applicationScope.specificity
      if leftSpecificity == rightSpecificity { return lhs.offset < rhs.offset }
      return leftSpecificity > rightSpecificity
    }.map(\.element)
  }

  private func legacyShouldArm(
    frame: TrackpadFrame,
    settings: TrackpadGestureSettings,
    bundleIdentifier: String?,
    modifiers: Set<TrackpadModifier>
  ) -> Bool {
    guard settings.isEnabled else { return false }
    let contacts = frame.contacts.filter(\.state.isTouching)
    guard (2...5).contains(contacts.count), Set(contacts.map(\.id)).count == contacts.count else {
      return false
    }
    let point = legacyPolicyCentroid(contacts.map(\.position))
    return settings.rules.contains { rule in
      let trigger = rule.trigger.normalized
      guard rule.isEnabled,
        trigger.kind == .contact,
        trigger.contactGesture == .tap,
        trigger.fingerCount == contacts.count,
        rule.applicationScope.matches(bundleIdentifier: bundleIdentifier),
        rule.requiredModifiers == modifiers,
        legacyRegionMatches(trigger.region, point: point)
      else { return false }
      switch rule.deviceScope {
      case .allSupported: return true
      case .builtInOnly: return frame.isBuiltIn
      case .externalOnly: return !frame.isBuiltIn
      }
    }
  }

  private func legacyEngineCentroid(_ points: [TrackpadPoint]) -> TrackpadPoint {
    guard !points.isEmpty else { return TrackpadPoint(x: 0, y: 0) }
    let sum = points.reduce((x: 0.0, y: 0.0)) { partial, point in
      (partial.x + point.x, partial.y + point.y)
    }
    return TrackpadPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
  }

  private func legacyPolicyCentroid(_ points: [TrackpadPoint]) -> TrackpadPoint {
    guard !points.isEmpty else { return TrackpadPoint(x: 0, y: 0) }
    let count = Double(points.count)
    return TrackpadPoint(
      x: points.map(\.x).reduce(0, +) / count,
      y: points.map(\.y).reduce(0, +) / count
    )
  }

  private func legacyEdgeContains(
    _ edge: TrackpadEdge,
    point: TrackpadPoint,
    width: Double
  ) -> Bool {
    switch edge {
    case .left: return point.x <= width
    case .right: return point.x >= 1 - width
    case .top: return point.y >= 1 - width
    case .bottom: return point.y <= width
    }
  }

  private func legacyRegionMatches(
    _ region: TrackpadGestureRegion,
    point: TrackpadPoint
  ) -> Bool {
    let low = 0.33
    let high = 0.67
    switch region {
    case .anywhere: return true
    case .center: return (low...high).contains(point.x) && (low...high).contains(point.y)
    case .left: return point.x < low
    case .right: return point.x > high
    case .topLeft: return point.x < low && point.y > high
    case .topMiddle: return (low...high).contains(point.x) && point.y > high
    case .topRight: return point.x > high && point.y > high
    case .leftMiddle: return point.x < low && (low...high).contains(point.y)
    case .rightMiddle: return point.x > high && (low...high).contains(point.y)
    case .bottomLeft: return point.x < low && point.y < low
    case .bottomMiddle: return (low...high).contains(point.x) && point.y < low
    case .bottomRight: return point.x > high && point.y < low
    }
  }

  // MARK: - Fixtures

  private func scopeMatrixRules() -> [TrackpadGestureRule] {
    var rules: [TrackpadGestureRule] = []
    for isEnabled in [true, false] {
      for scope in [TrackpadApplicationScope.all, editorScope, excludedScope()] {
        for deviceScope in TrackpadDeviceScope.allCases {
          for modifiers in [Set<TrackpadModifier>(), [.option], [.option, .shift]] {
            var candidate = rule(name: "rule \(rules.count)", scope: scope)
            candidate.isEnabled = isEnabled
            candidate.deviceScope = deviceScope
            candidate.requiredModifiers = modifiers
            rules.append(candidate)
          }
        }
      }
    }
    return rules
  }

  private func contextMatrix() -> [TrackpadRuleContext] {
    var contexts: [TrackpadRuleContext] = []
    for bundleIdentifier in ["com.example.editor", "com.example.other", nil] {
      for modifiers in [Set<TrackpadModifier>(), [.option], [.option, .shift]] {
        for isBuiltIn in [true, false] {
          contexts.append(
            TrackpadRuleContext(
              bundleIdentifier: bundleIdentifier,
              modifiers: modifiers,
              isBuiltIn: isBuiltIn
            )
          )
        }
      }
    }
    return contexts
  }

  private func excludedScope() -> TrackpadApplicationScope {
    TrackpadApplicationScope(
      mode: .excludedApplications,
      applications: [
        TrackpadApplicationIdentity(bundleIdentifier: "com.example.editor", name: "Editor")
      ]
    )
  }

  private func samplePoints() -> [TrackpadPoint] {
    let coordinates = [0.0, 0.02, 0.08, 0.14, 0.32, 0.33, 0.5, 0.67, 0.68, 0.86, 0.92, 0.98, 1.0]
    return coordinates.flatMap { x in
      coordinates.map { y in TrackpadPoint(x: x, y: y) }
    }
  }

  private func rule(
    name: String,
    scope: TrackpadApplicationScope,
    kind: TrackpadGestureKind = .contact
  ) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: name,
      applicationScope: scope,
      trigger: TrackpadGestureTrigger(kind: kind, fingerCount: 2, contactGesture: .tap),
      action: .system(.volumeUp)
    )
  }

  private func edgeRule(
    name: String,
    scope: TrackpadApplicationScope,
    edge: TrackpadEdge
  ) -> TrackpadGestureRule {
    TrackpadGestureRule(
      name: name,
      applicationScope: scope,
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: edge,
        minimumDistance: 0.02
      ),
      action: .system(.continuousVolume)
    )
  }

  private func settings(
    rules: [TrackpadGestureRule],
    edgeWidth: Double = 0.08
  ) -> TrackpadGestureSettings {
    TrackpadGestureSettings(
      isEnabled: true,
      hapticFeedbackEnabled: false,
      feedbackHUDEnabled: false,
      suppressesClickAfterMultiFingerTap: true,
      edgeWidth: edgeWidth,
      sensitivity: 1,
      rules: rules
    )
  }

  private func frame(
    contacts: [TrackpadContact],
    isBuiltIn: Bool = true
  ) -> TrackpadFrame {
    TrackpadFrame(
      deviceID: 1,
      isBuiltIn: isBuiltIn,
      timestamp: 0,
      frameNumber: 1,
      contacts: contacts
    )
  }
}
