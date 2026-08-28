import Foundation

/// Per-contact trace the engine accumulates for the life of a session and every
/// recognizer reads.
struct TrackpadContactHistory {
  let id: Int32
  let beganAt: TimeInterval
  let start: TrackpadPoint
  var last: TrackpadPoint
  var endedAt: TimeInterval?
  var maxTravel: Double = 0
  var maxDensity: Double = 0
  var maxSize: Double = 0
  var points: [TrackpadPoint]

  init(contact: TrackpadContact, timestamp: TimeInterval) {
    id = contact.id
    beganAt = timestamp
    start = contact.position
    last = contact.position
    maxDensity = contact.density
    maxSize = contact.size
    points = [contact.position]
  }

  mutating func update(contact: TrackpadContact, timestamp: TimeInterval) {
    last = contact.position
    maxTravel = max(maxTravel, start.distance(to: contact.position))
    maxDensity = max(maxDensity, contact.density)
    maxSize = max(maxSize, contact.size)
    if points.last?.distance(to: contact.position) ?? .infinity > 0.002 {
      if points.count == 256 { points.removeFirst() }
      points.append(contact.position)
    }
    if contact.state.isEnding { endedAt = timestamp }
  }
}

/// Read-only view of the engine's per-device session. Nothing here belongs to a single
/// gesture family; family state lives in `TrackpadRecognizerSessionState`.
struct TrackpadSessionSnapshot {
  let deviceID: UInt64
  let isBuiltIn: Bool
  let beganAt: TimeInterval
  let fullContactBeganAt: TimeInterval
  let lastTimestamp: TimeInterval
  let activeIDs: Set<Int32>
  let initialOrder: [Int32]
  let maxContactCount: Int
  let histories: [Int32: TrackpadContactHistory]
  /// Left-to-right by the order the contacts first landed, with any contact that joined
  /// later appended by starting x.
  let orderedHistories: [TrackpadContactHistory]
  let emittedRuleIDs: Set<UUID>
  let didEmitDiscrete: Bool

  var duration: TimeInterval { lastTimestamp - beganAt }
}

/// Everything one recognizer sees for one frame.
struct TrackpadRecognizerInput {
  let contacts: [Int32: TrackpadContact]
  let activeContacts: [TrackpadContact]
  let beganIDs: Set<Int32>
  let endedIDs: Set<Int32>
  let session: TrackpadSessionSnapshot
  let edgeWidth: Double
  let sensitivity: Double
  /// Enabled, in-scope rules for this frame ordered by specificity. Shared by every
  /// family so one frame walks the rule table once.
  let eligibleRules: [TrackpadGestureRule]
  let state: TrackpadRecognizerSessionState?
}

/// A rule the recognizer decided has fired. The engine turns it into a
/// `TrackpadGestureMatch` and applies the session-wide consequences.
struct TrackpadRecognizedGesture {
  let rule: TrackpadGestureRule
  var direction: TrackpadDirection?
  var continuousDelta: Double = 0
  /// A discrete result closes the session: no completion family may fire afterwards and
  /// the same rule cannot fire twice.
  var isDiscrete: Bool = false
}

/// Input a family needs suppressed while any of its rules is enabled. The service reads
/// this instead of testing for particular gesture kinds.
enum TrackpadInputSuppressionNeed: String, CaseIterable, Hashable {
  case none
  /// Native scrolling must be consumed while the gesture owns the trackpad.
  case scrollWheel
  /// The left click that follows the gesture may be consumed, but only when the user
  /// opted in.
  case optInLeftClick
}

/// Mutable state one family keeps for the length of a session. Reference semantics keep
/// the engine's session value cheap to copy and free of per-frame boxing.
protocol TrackpadRecognizerSessionState: AnyObject {}

/// One gesture family. Adding a family means adding a type here and one line to
/// `TrackpadRecognizerRegistry`; the engine and the service stay untouched.
protocol TrackpadGestureRecognizer: AnyObject {
  static var kind: TrackpadGestureKind { get }
  static var suppression: TrackpadInputSuppressionNeed { get }
  /// Finger counts this family can recognize. The rule editor offers exactly this range,
  /// so a count the family would silently ignore cannot be configured.
  static var supportedFingerCounts: ClosedRange<Int> { get }

  /// Scratch space for a new session, or nil for a family that only judges completed
  /// sessions.
  func makeSessionState() -> TrackpadRecognizerSessionState?

  /// Per-frame hook. Families that recognize before the contacts lift work here.
  func consume(_ input: TrackpadRecognizerInput) -> [TrackpadRecognizedGesture]

  /// Judged once every contact has lifted, once per eligible rule. The engine walks the
  /// rules in specificity order, so a family cannot promote its own rules by being
  /// registered earlier. `input.state` is nil here: a family that only judges completed
  /// sessions reads the contact histories, not scratch space.
  func matchesCompletedSession(rule: TrackpadGestureRule, input: TrackpadRecognizerInput) -> Bool

  /// Direction reported alongside a completed match, for feedback and diagnostics.
  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection?

  /// Drops state that outlives a session, such as a pending first tap.
  func reset(deviceID: UInt64?)
}

extension TrackpadGestureRecognizer {
  static var supportedFingerCounts: ClosedRange<Int> { 1...5 }

  var kind: TrackpadGestureKind { Self.kind }
  var suppression: TrackpadInputSuppressionNeed { Self.suppression }
  var supportedFingerCounts: ClosedRange<Int> { Self.supportedFingerCounts }

  func makeSessionState() -> TrackpadRecognizerSessionState? { nil }
  func consume(_ input: TrackpadRecognizerInput) -> [TrackpadRecognizedGesture] { [] }
  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool { false }
  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection? { nil }
  func reset(deviceID: UInt64?) {}
}

enum TrackpadRecognizerRegistry {
  /// Registration order is the evaluation order. The per-frame families come first so a
  /// tip tap still wins over the completion families it would otherwise race.
  static func makeRecognizers() -> [TrackpadGestureRecognizer] {
    [
      TrackpadTipTapRecognizer(),
      TrackpadEdgeContinuousRecognizer(),
      TrackpadContactRecognizer(),
      TrackpadSwipeRecognizer(),
      TrackpadEdgeEntrySwipeRecognizer(),
      TrackpadPinchRecognizer(),
      TrackpadFingerSwipeRecognizer(),
      TrackpadDrawingRecognizer(),
    ]
  }

  private static let suppressionByKind: [TrackpadGestureKind: TrackpadInputSuppressionNeed] =
    Dictionary(uniqueKeysWithValues: makeRecognizers().map { ($0.kind, $0.suppression) })

  private static let fingerCountsByKind: [TrackpadGestureKind: ClosedRange<Int>] =
    Dictionary(uniqueKeysWithValues: makeRecognizers().map { ($0.kind, $0.supportedFingerCounts) })

  static var registeredKinds: Set<TrackpadGestureKind> { Set(suppressionByKind.keys) }

  static func suppression(for kind: TrackpadGestureKind) -> TrackpadInputSuppressionNeed {
    suppressionByKind[kind] ?? TrackpadInputSuppressionNeed.none
  }

  /// What the rule editor may offer for a family, straight from the recognizer that will
  /// have to honour it.
  static func supportedFingerCounts(for kind: TrackpadGestureKind) -> ClosedRange<Int> {
    fingerCountsByKind[kind] ?? 1...5
  }

  /// What the currently enabled rules require the service to suppress.
  static func suppressionNeeds(
    for rules: [TrackpadGestureRule]
  ) -> Set<TrackpadInputSuppressionNeed> {
    var needs = Set<TrackpadInputSuppressionNeed>()
    for rule in rules where rule.isEnabled {
      let need = suppression(for: rule.trigger.kind)
      if need != .none { needs.insert(need) }
    }
    return needs
  }
}

// MARK: - Tip tap

/// A finger lifts off a resting hand and taps back down in place while the others hold
/// still, and may keep tapping for as long as the hand stays down.
final class TrackpadTipTapRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.tipTap
  static let suppression = TrackpadInputSuppressionNeed.none
  /// A fifth contact is a resting hand, not an anchor plus a tapping finger.
  static let supportedFingerCounts = 2...4

  /// How far the re-contact may land from where the finger lifted.
  private static let recontactRadius = 0.2
  /// A re-contact held longer than this is a press, not a tap.
  private static let maximumRecontactDuration: TimeInterval = 0.35
  /// Two emissions closer together than this are one finger bouncing, not two requests.
  private static let repeatCooldown: TimeInterval = 0.12
  private static let nearSpacing = 0.23
  private static let farSpacing = 0.4

  final class SessionState: TrackpadRecognizerSessionState {
    struct Pending {
      let selectedFingerIndex: Int
      let initialPosition: TrackpadPoint
      let initialTravel: Double
      let gapBeganAt: TimeInterval
      let heldDuration: TimeInterval
      let anchorIDs: Set<Int32>
      var recontactID: Int32?
      var recontactBeganAt: TimeInterval?
    }

    var pending: Pending?
    var lastEmittedAt: TimeInterval?
  }

  func makeSessionState() -> TrackpadRecognizerSessionState? { SessionState() }

  func consume(_ input: TrackpadRecognizerInput) -> [TrackpadRecognizedGesture] {
    guard let state = input.state as? SessionState else { return [] }
    let session = input.session
    // A tip tap does close the session for the other families, but not for this one: the
    // family exists so a held hand can keep tapping without lifting off.
    guard Self.supportedFingerCounts.contains(session.maxContactCount) else { return [] }

    if state.pending == nil,
      input.endedIDs.count == 1,
      let endedID = input.endedIDs.first,
      let selectedIndex = session.initialOrder.firstIndex(of: endedID),
      let history = session.histories[endedID],
      session.activeIDs.count == session.maxContactCount - 1
    {
      state.pending = SessionState.Pending(
        selectedFingerIndex: selectedIndex,
        initialPosition: history.start,
        initialTravel: history.maxTravel,
        gapBeganAt: session.lastTimestamp,
        heldDuration: session.lastTimestamp - session.fullContactBeganAt,
        anchorIDs: session.activeIDs,
        recontactID: nil,
        recontactBeganAt: nil
      )
      return []
    }

    if var pending = state.pending,
      pending.recontactID == nil,
      input.beganIDs.count == 1,
      let newID = input.beganIDs.first,
      pending.anchorIDs.isSubset(of: session.activeIDs),
      let contact = input.contacts[newID],
      contact.position.distance(to: pending.initialPosition) <= Self.recontactRadius
    {
      pending.recontactID = newID
      pending.recontactBeganAt = session.lastTimestamp
      state.pending = pending
      return []
    }

    guard let pending = state.pending,
      let recontactID = pending.recontactID,
      input.endedIDs.contains(recontactID),
      let recontactStart = pending.recontactBeganAt,
      let history = session.histories[recontactID],
      pending.anchorIDs.isSubset(of: session.activeIDs),
      session.activeIDs.count == pending.anchorIDs.count
    else { return [] }

    // The tapping finger is up again with the anchors still down, which is exactly the
    // state the first lift armed. Re-arming here is what lets the next tap count without
    // the whole hand lifting off first, whatever this one turns out to be.
    //
    // Travel starts over at zero. The arming lift reports how far the finger strayed while
    // it rested, which nothing else checks, but a tap answers for its own travel below —
    // carrying that forward would let one smeared tap disqualify the clean tap after it.
    state.pending = SessionState.Pending(
      selectedFingerIndex: pending.selectedFingerIndex,
      initialPosition: history.start,
      initialTravel: 0,
      gapBeganAt: session.lastTimestamp,
      heldDuration: session.lastTimestamp - session.fullContactBeganAt,
      anchorIDs: pending.anchorIDs,
      recontactID: nil,
      recontactBeganAt: nil
    )

    let tapDuration = session.lastTimestamp - recontactStart
    let eligible = input.eligibleRules.filter {
      $0.trigger.kind == .tipTap
        && $0.trigger.fingerCount == session.maxContactCount
        && $0.trigger.selectedFingerIndex == pending.selectedFingerIndex
    }
    guard let rule = eligible.first(where: { rule in
      let trigger = rule.trigger.normalized
      let anchorsStayedStill = pending.anchorIDs.allSatisfy { id in
        guard let anchor = session.histories[id] else { return false }
        return anchor.maxTravel <= trigger.movementTolerance
      }
      guard pending.heldDuration >= trigger.holdDuration,
        session.lastTimestamp - pending.gapBeganAt <= trigger.maximumDuration,
        tapDuration <= min(Self.maximumRecontactDuration, trigger.maximumDuration),
        pending.initialTravel <= trigger.movementTolerance,
        history.maxTravel <= trigger.movementTolerance,
        anchorsStayedStill
      else { return false }
      return spacingMatches(
        trigger.tapSpacing,
        session: session,
        selectedIndex: pending.selectedFingerIndex
      )
    }) else { return [] }

    if let lastEmittedAt = state.lastEmittedAt,
      session.lastTimestamp - lastEmittedAt < Self.repeatCooldown
    {
      return []
    }
    state.lastEmittedAt = session.lastTimestamp

    return [TrackpadRecognizedGesture(rule: rule, isDiscrete: true)]
  }

  private func spacingMatches(
    _ spacing: TrackpadTapSpacing,
    session: TrackpadSessionSnapshot,
    selectedIndex: Int
  ) -> Bool {
    guard session.initialOrder.indices.contains(selectedIndex),
      let selected = session.histories[session.initialOrder[selectedIndex]]
    else { return false }
    let nearest = session.initialOrder.enumerated().compactMap { index, id -> Double? in
      guard index != selectedIndex, let history = session.histories[id] else { return nil }
      return selected.start.distance(to: history.start)
    }.min() ?? 0
    switch spacing {
    case .near: return nearest <= Self.nearSpacing
    case .normal: return true
    case .far: return nearest >= Self.farSpacing
    }
  }
}

// MARK: - Continuous edge

/// Two fingers sliding along one edge, quantized into repeated steps while they stay in
/// the corridor.
final class TrackpadEdgeContinuousRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.edgeContinuous
  static let suppression = TrackpadInputSuppressionNeed.scrollWheel
  static let supportedFingerCounts = requiredContactCount...requiredContactCount

  private static let requiredContactCount = 2
  private static let minimumStep = 0.004
  private static let cooldown: TimeInterval = 0.035
  private static let maximumStepsPerFrame = 4

  final class SessionState: TrackpadRecognizerSessionState {
    var remainders: [UUID: Double] = [:]
    var lastFire: [UUID: TimeInterval] = [:]
    var lastPositions: [UUID: TrackpadPoint] = [:]
    var cancelledRuleIDs = Set<UUID>()
  }

  func makeSessionState() -> TrackpadRecognizerSessionState? { SessionState() }

  func consume(_ input: TrackpadRecognizerInput) -> [TrackpadRecognizedGesture] {
    guard let state = input.state as? SessionState else { return [] }
    let session = input.session
    let edgeRules = input.eligibleRules.filter {
      $0.trigger.kind == .edgeContinuous && $0.trigger.fingerCount == Self.requiredContactCount
    }
    guard !edgeRules.isEmpty else { return [] }

    if session.maxContactCount < Self.requiredContactCount {
      return []
    }
    guard session.maxContactCount == Self.requiredContactCount,
      session.histories.count == Self.requiredContactCount,
      input.activeContacts.count == Self.requiredContactCount
    else {
      cancel(edgeRules, state: state)
      return []
    }

    let activeHistories: [(contact: TrackpadContact, history: TrackpadContactHistory)] =
      input.activeContacts.compactMap { contact in
        guard let history = session.histories[contact.id] else { return nil }
        return (contact, history)
      }
    guard activeHistories.count == Self.requiredContactCount else {
      cancel(edgeRules, state: state)
      return []
    }
    let currentCentroid = TrackpadGeometry.centroid(activeHistories.map { $0.contact.position })

    var gestures: [TrackpadRecognizedGesture] = []
    for rule in edgeRules {
      guard !state.cancelledRuleIDs.contains(rule.id) else { continue }
      let trigger = rule.trigger.normalized
      guard activeHistories.allSatisfy({ pair in
        TrackpadGeometry.edgeContains(trigger.edge, point: pair.history.start, width: input.edgeWidth)
          && TrackpadGeometry.edgeContains(
            trigger.edge,
            point: pair.contact.position,
            width: TrackpadGeometry.edgeCorridorWidth(input.edgeWidth, expanded: true)
          )
      }) else {
        state.cancelledRuleIDs.insert(rule.id)
        state.remainders.removeValue(forKey: rule.id)
        state.lastPositions.removeValue(forKey: rule.id)
        continue
      }

      guard let previousPosition = state.lastPositions[rule.id] else {
        state.lastPositions[rule.id] = currentCentroid
        continue
      }
      state.lastPositions[rule.id] = currentCentroid
      let rawDelta: Double
      switch trigger.edge {
      case .left, .right: rawDelta = currentCentroid.y - previousPosition.y
      case .top, .bottom: rawDelta = currentCentroid.x - previousPosition.x
      }
      let delta = trigger.isInverted ? -rawDelta : rawDelta
      var remainder = state.remainders[rule.id, default: 0] + delta
      let threshold = max(Self.minimumStep, trigger.minimumDistance / input.sensitivity)
      let availableSteps = Int(abs(remainder) / threshold)
      guard availableSteps > 0 else {
        state.remainders[rule.id] = remainder
        continue
      }
      let lastFire = state.lastFire[rule.id] ?? -.greatestFiniteMagnitude
      guard session.lastTimestamp - lastFire >= Self.cooldown else {
        state.remainders[rule.id] = remainder
        continue
      }
      let signedSteps = (remainder > 0 ? 1 : -1) * min(Self.maximumStepsPerFrame, availableSteps)
      remainder -= Double(signedSteps) * threshold
      state.remainders[rule.id] = remainder
      state.lastFire[rule.id] = session.lastTimestamp
      gestures.append(
        TrackpadRecognizedGesture(
          rule: rule,
          direction: TrackpadGeometry.direction(
            forSignedDelta: Double(signedSteps),
            vertical: trigger.edge == .left || trigger.edge == .right
          ),
          continuousDelta: Double(signedSteps)
        )
      )
      break
    }
    return gestures
  }

  private func cancel(_ rules: [TrackpadGestureRule], state: SessionState) {
    for rule in rules {
      state.cancelledRuleIDs.insert(rule.id)
      state.remainders.removeValue(forKey: rule.id)
      state.lastPositions.removeValue(forKey: rule.id)
    }
  }
}

// MARK: - Completed-session families

/// Taps, double taps, clicks, and force clicks landing in a configured region.
final class TrackpadContactRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.contact
  static let suppression = TrackpadInputSuppressionNeed.optInLeftClick
  static let supportedFingerCounts = 1...5

  private static let maximumDoubleTapInterval: TimeInterval = 0.5
  private static let clickDensity = 1.0
  private static let clickSize = 2.0
  private static let forceClickDensity = 2.2
  private static let forceClickSize = 4.0

  private struct DoubleTapKey: Hashable {
    let deviceID: UInt64
    let ruleID: UUID
  }

  private struct LastTap {
    let timestamp: TimeInterval
    let position: TrackpadPoint
  }

  /// A first tap has to outlive the session that produced it, so this is the one piece of
  /// recognizer state the engine keeps between sessions.
  private var lastTaps: [DoubleTapKey: LastTap] = [:]

  func reset(deviceID: UInt64?) {
    if let deviceID {
      lastTaps = lastTaps.filter { $0.key.deviceID != deviceID }
    } else {
      lastTaps.removeAll()
    }
  }

  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool {
    let trigger = rule.trigger.normalized
    let session = input.session
    let centroidStart = TrackpadGeometry.centroid(session.orderedHistories.map(\.start))
    guard session.duration <= trigger.maximumDuration,
      session.orderedHistories.allSatisfy({ $0.maxTravel <= trigger.movementTolerance }),
      TrackpadGeometry.regionMatches(trigger.region, point: centroidStart)
    else { return false }

    switch trigger.contactGesture {
    case .tap:
      return true
    case .doubleTap:
      let key = DoubleTapKey(deviceID: session.deviceID, ruleID: rule.id)
      if let previous = lastTaps[key] {
        let interval = session.lastTimestamp - previous.timestamp
        if interval >= 0,
          interval <= min(Self.maximumDoubleTapInterval, trigger.maximumDuration),
          previous.position.distance(to: centroidStart) <= trigger.movementTolerance * 2
        {
          lastTaps.removeValue(forKey: key)
          return true
        }
      }
      lastTaps[key] = LastTap(timestamp: session.lastTimestamp, position: centroidStart)
      return false
    case .click:
      return session.orderedHistories.contains {
        $0.maxDensity >= Self.clickDensity || $0.maxSize >= Self.clickSize
      }
    case .forceClick:
      return session.orderedHistories.contains {
        $0.maxDensity >= Self.forceClickDensity || $0.maxSize >= Self.forceClickSize
      }
    }
  }
}

/// The whole hand travels far enough, fast enough, in one direction.
final class TrackpadSwipeRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.swipe
  static let suppression = TrackpadInputSuppressionNeed.none
  static let supportedFingerCounts = 2...5

  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool {
    let trigger = rule.trigger.normalized
    let session = input.session
    guard session.duration <= trigger.maximumDuration else { return false }
    let centroidStart = TrackpadGeometry.centroid(session.orderedHistories.map(\.start))
    let centroidEnd = TrackpadGeometry.centroid(session.orderedHistories.map(\.last))
    let displacement = centroidStart.distance(to: centroidEnd)
    guard displacement >= trigger.minimumDistance,
      TrackpadGeometry.direction(from: centroidStart, to: centroidEnd) == trigger.direction
    else { return false }
    return TrackpadGeometry.velocity(distance: displacement, duration: session.duration)
      >= trigger.minimumVelocity
  }

  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection? {
    rule.trigger.direction
  }
}

/// A swipe that has to start inside an edge corridor, so it can be told apart from the
/// same motion begun mid-pad.
final class TrackpadEdgeEntrySwipeRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.edgeEntrySwipe
  static let suppression = TrackpadInputSuppressionNeed.none
  static let supportedFingerCounts = 2...5

  /// Entry is judged against a wider corridor than a continuous edge gesture, because the
  /// hand is already moving when it lands.
  private static let entryCorridorScale = 1.5

  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool {
    let trigger = rule.trigger.normalized
    let session = input.session
    guard session.duration <= trigger.maximumDuration else { return false }
    let centroidStart = TrackpadGeometry.centroid(session.orderedHistories.map(\.start))
    let centroidEnd = TrackpadGeometry.centroid(session.orderedHistories.map(\.last))
    let displacement = centroidStart.distance(to: centroidEnd)
    guard displacement >= trigger.minimumDistance,
      TrackpadGeometry.direction(from: centroidStart, to: centroidEnd) == trigger.direction,
      TrackpadGeometry.edgeContains(
        trigger.edge,
        point: centroidStart,
        width: input.edgeWidth * Self.entryCorridorScale
      )
    else { return false }
    return TrackpadGeometry.velocity(distance: displacement, duration: session.duration)
      >= trigger.minimumVelocity
  }

  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection? {
    rule.trigger.direction
  }
}

/// The contacts spread apart or draw together.
final class TrackpadPinchRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.pinch
  static let suppression = TrackpadInputSuppressionNeed.none
  static let supportedFingerCounts = 2...4

  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool {
    let trigger = rule.trigger.normalized
    let session = input.session
    guard session.duration <= trigger.maximumDuration,
      session.orderedHistories.count >= 2
    else { return false }
    let startSpread = TrackpadGeometry.spread(session.orderedHistories.map(\.start))
    let endSpread = TrackpadGeometry.spread(session.orderedHistories.map(\.last))
    let change = endSpread - startSpread
    guard abs(change) >= trigger.minimumDistance else { return false }
    return trigger.pinchDirection == .outward ? change > 0 : change < 0
  }

  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection? {
    rule.trigger.pinchDirection == .outward ? .right : .left
  }
}

/// One nominated finger swipes while the rest of the hand stays put.
final class TrackpadFingerSwipeRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.fingerSwipe
  static let suppression = TrackpadInputSuppressionNeed.none
  static let supportedFingerCounts = 2...5

  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool {
    let trigger = rule.trigger.normalized
    let histories = input.session.orderedHistories
    guard input.session.duration <= trigger.maximumDuration else { return false }
    guard histories.indices.contains(trigger.selectedFingerIndex) else { return false }
    let selected = histories[trigger.selectedFingerIndex]
    let selectedDistance = selected.start.distance(to: selected.last)
    guard selectedDistance >= trigger.minimumDistance,
      TrackpadGeometry.direction(from: selected.start, to: selected.last) == trigger.direction
    else { return false }
    return histories.enumerated().allSatisfy { index, history in
      index == trigger.selectedFingerIndex || history.maxTravel <= trigger.movementTolerance
    }
  }

  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection? {
    rule.trigger.direction
  }
}

/// A traced shape scored against a stored template with the $1 unistroke recognizer.
final class TrackpadDrawingRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.drawing
  static let suppression = TrackpadInputSuppressionNeed.none
  static let supportedFingerCounts = 1...5

  /// Below this many samples the score is noise on both sides of the comparison.
  private static let minimumSampleCount = 8
  private static let resampleCount = 64
  /// Mean point distance at which the score reaches zero.
  private static let scoreFalloff = 0.5
  private static let thumbCorridorScale = 1.5

  func matchesCompletedSession(
    rule: TrackpadGestureRule,
    input: TrackpadRecognizerInput
  ) -> Bool {
    let trigger = rule.trigger.normalized
    guard input.session.duration <= trigger.maximumDuration else { return false }
    guard let path = drawingPath(
      for: trigger,
      histories: input.session.orderedHistories,
      edgeWidth: input.edgeWidth
    ),
      path.count >= Self.minimumSampleCount,
      trigger.drawingTemplate.count >= Self.minimumSampleCount
    else { return false }
    return unistrokeScore(path, template: trigger.drawingTemplate) >= trigger.minimumDrawingScore
  }

  private func drawingPath(
    for trigger: TrackpadGestureTrigger,
    histories: [TrackpadContactHistory],
    edgeWidth: Double
  ) -> [TrackpadPoint]? {
    switch trigger.drawingActivation {
    case .modifier:
      return histories.max(by: { $0.points.count < $1.points.count })?.points
    case .bottomThumb:
      let thumbCorridor = edgeWidth * Self.thumbCorridorScale
      guard histories.contains(where: { $0.start.y <= thumbCorridor }) else { return nil }
      return histories.filter { $0.start.y > thumbCorridor }
        .max(by: { $0.points.count < $1.points.count })?.points
    case .holdTap:
      guard histories.count >= 2,
        let anchor = histories.min(by: { $0.beganAt < $1.beganAt }),
        anchor.maxTravel <= trigger.movementTolerance
      else { return nil }
      return histories.filter {
        $0.id != anchor.id && $0.beganAt - anchor.beganAt >= trigger.holdDuration
      }.max(by: { $0.points.count < $1.points.count })?.points
    }
  }

  private func unistrokeScore(_ path: [TrackpadPoint], template: [TrackpadPoint]) -> Double {
    let normalizedPath = normalizeStroke(path)
    let normalizedTemplate = normalizeStroke(template)
    guard normalizedPath.count == normalizedTemplate.count, !normalizedPath.isEmpty else { return 0 }
    let distance = zip(normalizedPath, normalizedTemplate)
      .map { pair in pair.0.distance(to: pair.1) }
      .reduce(0, +) / Double(normalizedPath.count)
    return max(0, 1 - distance / Self.scoreFalloff)
  }

  private func normalizeStroke(_ points: [TrackpadPoint]) -> [TrackpadPoint] {
    let sampled = resample(points, count: Self.resampleCount)
    guard sampled.count > 1 else { return sampled }
    let center = TrackpadGeometry.centroid(sampled)
    let angle = atan2(sampled[0].y - center.y, sampled[0].x - center.x)
    let rotated = sampled.map { point -> TrackpadPoint in
      let dx = point.x - center.x
      let dy = point.y - center.y
      return TrackpadPoint(
        x: dx * cos(-angle) - dy * sin(-angle),
        y: dx * sin(-angle) + dy * cos(-angle)
      )
    }
    let minX = rotated.map(\.x).min() ?? 0
    let maxX = rotated.map(\.x).max() ?? 1
    let minY = rotated.map(\.y).min() ?? 0
    let maxY = rotated.map(\.y).max() ?? 1
    let scale = max(0.0001, max(maxX - minX, maxY - minY))
    let scaled = rotated.map { TrackpadPoint(x: $0.x / scale, y: $0.y / scale) }
    let scaledCenter = TrackpadGeometry.centroid(scaled)
    return scaled.map { TrackpadPoint(x: $0.x - scaledCenter.x, y: $0.y - scaledCenter.y) }
  }

  private func resample(_ points: [TrackpadPoint], count: Int) -> [TrackpadPoint] {
    guard points.count > 1, count > 1 else { return points }
    let length = zip(points, points.dropFirst())
      .map { pair in pair.0.distance(to: pair.1) }
      .reduce(0, +)
    guard length > 0 else { return Array(repeating: points[0], count: count) }
    let interval = length / Double(count - 1)
    var result = [points[0]]
    var working = points
    var accumulated = 0.0
    var index = 1
    while index < working.count, result.count < count - 1 {
      let previous = working[index - 1]
      let current = working[index]
      let segment = previous.distance(to: current)
      if accumulated + segment >= interval {
        let ratio = (interval - accumulated) / max(segment, 0.000001)
        let inserted = TrackpadPoint(
          x: previous.x + ratio * (current.x - previous.x),
          y: previous.y + ratio * (current.y - previous.y)
        )
        result.append(inserted)
        working.insert(inserted, at: index)
        accumulated = 0
        index += 1
      } else {
        accumulated += segment
        index += 1
      }
    }
    while result.count < count { result.append(points.last!) }
    return result
  }
}
