import Foundation

/// Everything a trackpad rule predicate needs to know about the moment being evaluated.
/// Recognition reads the modifiers latched when the session began; the input-suppression
/// policies read the live modifiers, because they run before a session exists.
struct TrackpadRuleContext: Equatable {
  var bundleIdentifier: String?
  var modifiers: Set<TrackpadModifier>
  var isBuiltIn: Bool

  init(bundleIdentifier: String?, modifiers: Set<TrackpadModifier>, isBuiltIn: Bool) {
    self.bundleIdentifier = bundleIdentifier
    self.modifiers = modifiers
    self.isBuiltIn = isBuiltIn
  }
}

/// The single authority on which rules may fire right now and in what order. The engine
/// and both suppression policies share it so a rule can never be eligible for one and
/// invisible to the other.
enum TrackpadRuleMatcher {
  /// Enabled rules whose application, modifier, and device scopes admit `context`,
  /// ordered so a rule scoped to specific applications outranks an all-applications rule
  /// and configuration order breaks ties.
  static func eligibleRules(
    _ rules: [TrackpadGestureRule],
    context: TrackpadRuleContext,
    where predicate: (TrackpadGestureRule) -> Bool = { _ in true }
  ) -> [TrackpadGestureRule] {
    let candidates = rules.enumerated().filter { _, rule in
      matches(rule, context: context) && predicate(rule)
    }
    // This runs for every frame on the suppression path, where no match or a single match
    // is the common case.
    guard candidates.count > 1 else { return candidates.map(\.element) }
    return candidates.sorted { lhs, rhs in
      let leftSpecificity = lhs.element.applicationScope.specificity
      let rightSpecificity = rhs.element.applicationScope.specificity
      if leftSpecificity == rightSpecificity { return lhs.offset < rhs.offset }
      return leftSpecificity > rightSpecificity
    }.map(\.element)
  }

  /// Whether a single rule is in scope, ignoring its trigger geometry.
  static func matches(_ rule: TrackpadGestureRule, context: TrackpadRuleContext) -> Bool {
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
}

/// The single implementation of the normalized-coordinate math every trackpad layer
/// needs. Positions are normalized to 0...1 with the origin at the bottom-left.
enum TrackpadGeometry {
  /// A gesture that already owns an edge may drift this far past its configured corridor
  /// before it is cancelled, so a small wobble does not interrupt an active adjustment.
  static let edgeCorridorSlack = 0.06
  /// However wide the corridor is configured or expanded to be, it never swallows more
  /// than roughly a third of the trackpad.
  static let maximumEdgeCorridorWidth = 0.35

  private static let lowThird = 0.33
  private static let highThird = 0.67

  static func centroid(_ points: [TrackpadPoint]) -> TrackpadPoint {
    guard !points.isEmpty else { return TrackpadPoint(x: 0, y: 0) }
    let sum = points.reduce((x: 0.0, y: 0.0)) { partial, point in
      (partial.x + point.x, partial.y + point.y)
    }
    return TrackpadPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
  }

  /// Mean distance from the centroid, used to tell a pinch from a spread.
  static func spread(_ points: [TrackpadPoint]) -> Double {
    guard points.count >= 2 else { return 0 }
    let center = centroid(points)
    return points.map { center.distance(to: $0) }.reduce(0, +) / Double(points.count)
  }

  static func velocity(distance: Double, duration: TimeInterval) -> Double {
    distance / max(0.001, duration)
  }

  static func direction(from start: TrackpadPoint, to end: TrackpadPoint) -> TrackpadDirection {
    let dx = end.x - start.x
    let dy = end.y - start.y
    if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
    return dy >= 0 ? .up : .down
  }

  static func direction(forSignedDelta delta: Double, vertical: Bool) -> TrackpadDirection {
    if vertical { return delta >= 0 ? .up : .down }
    return delta >= 0 ? .right : .left
  }

  static func edgeCorridorWidth(_ configuredWidth: Double, expanded: Bool = false) -> Double {
    min(maximumEdgeCorridorWidth, configuredWidth + (expanded ? edgeCorridorSlack : 0))
  }

  /// How far past the corridor the second finger of an edge gesture may sit. A corridor is
  /// narrower than the gap between two fingers laid side by side, so without this the only
  /// posture that works is both fingers stacked inside the strip — which is not how a hand
  /// rests on an edge.
  static let edgeCompanionReach = 0.14

  /// Distance from the named edge, so every edge test is the same comparison with a
  /// different axis rather than four transcriptions of it.
  static func edgeDepth(_ edge: TrackpadEdge, point: TrackpadPoint) -> Double {
    switch edge {
    case .left: return point.x
    case .right: return 1 - point.x
    case .top: return 1 - point.y
    case .bottom: return point.y
    }
  }

  static func edgeContains(
    _ edge: TrackpadEdge,
    point: TrackpadPoint,
    width: Double
  ) -> Bool {
    edgeDepth(edge, point: point) <= width
  }

  /// Whether a hand is working this edge. The finger nearest the edge has to be inside the
  /// corridor; its partner only has to be within reach of it. That admits the postures
  /// people actually use — stacked along the edge, laid across it side by side, or at any
  /// angle between — while still taking a deliberate placement at the edge to start.
  static func edgeAdmits(
    _ edge: TrackpadEdge,
    points: [TrackpadPoint],
    width: Double
  ) -> Bool {
    let depths = points.map { edgeDepth(edge, point: $0) }
    guard let nearest = depths.min() else { return false }
    return nearest <= width && depths.allSatisfy { $0 <= width + edgeCompanionReach }
  }

  static func regionMatches(_ region: TrackpadGestureRegion, point: TrackpadPoint) -> Bool {
    let low = lowThird
    let high = highThird
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
}
