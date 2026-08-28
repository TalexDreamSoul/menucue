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
  /// How far the fingers actually travelled to earn `continuousDelta`, scaled by
  /// sensitivity: 1.0 is a full pass of the trackpad at sensitivity 1. Step count alone
  /// cannot say how much to adjust, because a step is worth whatever the rule's
  /// `minimumDistance` says it is.
  var continuousTravel: Double = 0
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

/// When a family that needs an input suppressed comes to own it. The service reads this
/// instead of asking which family it is looking at.
enum TrackpadInputSuppressionOwnership: String, CaseIterable, Hashable {
  /// The service decides from the raw contacts, before recognition: the family's geometry
  /// is visible in the frame itself, so suppression is in place before the first result and
  /// a result that arrives without it is not the gesture the user meant.
  case rawFrameGeometry
  /// The family's own first result takes the input and holds it until the contacts end,
  /// because a raw frame cannot tell the gesture from ordinary movement until it happens.
  case activeSession
}

/// Mutable state one family keeps for the length of a session. Reference semantics keep
/// the engine's session value cheap to copy and free of per-frame boxing.
protocol TrackpadRecognizerSessionState: AnyObject {}

/// One gesture family. Adding a family means adding a type here and one line to
/// `TrackpadRecognizerRegistry`; the engine and the service stay untouched.
protocol TrackpadGestureRecognizer: AnyObject {
  static var kind: TrackpadGestureKind { get }
  static var suppression: TrackpadInputSuppressionNeed { get }
  /// How this family comes to own what it suppresses. Only meaningful alongside a
  /// `suppression` other than `.none`.
  static var suppressionOwnership: TrackpadInputSuppressionOwnership { get }
  /// Whether the pointer has to hold still from this family's first result until the
  /// session ends, because the fingers driving the gesture are also driving the cursor.
  static var freezesPointer: Bool { get }
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
  static var suppressionOwnership: TrackpadInputSuppressionOwnership { .rawFrameGeometry }
  static var freezesPointer: Bool { false }
  static var supportedFingerCounts: ClosedRange<Int> { 1...5 }

  var kind: TrackpadGestureKind { Self.kind }
  var suppression: TrackpadInputSuppressionNeed { Self.suppression }
  var suppressionOwnership: TrackpadInputSuppressionOwnership { Self.suppressionOwnership }
  var freezesPointer: Bool { Self.freezesPointer }
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
      TrackpadAnchoredSlideRecognizer(),
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

  private static let ownershipByKind: [TrackpadGestureKind: TrackpadInputSuppressionOwnership] =
    Dictionary(uniqueKeysWithValues: makeRecognizers().map { ($0.kind, $0.suppressionOwnership) })

  private static let fingerCountsByKind: [TrackpadGestureKind: ClosedRange<Int>] =
    Dictionary(uniqueKeysWithValues: makeRecognizers().map { ($0.kind, $0.supportedFingerCounts) })

  private static let pointerFreezeByKind: [TrackpadGestureKind: Bool] =
    Dictionary(uniqueKeysWithValues: makeRecognizers().map { ($0.kind, $0.freezesPointer) })

  static var registeredKinds: Set<TrackpadGestureKind> { Set(suppressionByKind.keys) }

  static func suppression(for kind: TrackpadGestureKind) -> TrackpadInputSuppressionNeed {
    suppressionByKind[kind] ?? TrackpadInputSuppressionNeed.none
  }

  /// Whether the service arms this family's suppression from the raw frames or the family
  /// takes it with its own first result.
  static func suppressionOwnership(
    for kind: TrackpadGestureKind
  ) -> TrackpadInputSuppressionOwnership {
    ownershipByKind[kind] ?? .rawFrameGeometry
  }

  /// Whether a result from this family holds the pointer still for the rest of the session.
  static func freezesPointer(for kind: TrackpadGestureKind) -> Bool {
    pointerFreezeByKind[kind] ?? false
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

    // A pending gap is a claim about the hand: these fingers are resting, that one lifted.
    // Another finger leaving, or an anchor going up, makes it a claim about a hand that is
    // no longer on the trackpad. Dropping it here is what lets the next lift arm on this
    // same frame: while a stale gap survived, every lift that was not the recontact it was
    // waiting for fell through to nothing, and the arming branch below could not run because
    // a pending was still set — so a hand that had tapped once could only ever tap again
    // with the same finger.
    if let pending = state.pending,
      !pending.anchorIDs.isSubset(of: session.activeIDs)
        || input.endedIDs.contains(where: { $0 != pending.recontactID })
    {
      state.pending = nil
    }

    if state.pending == nil,
      input.endedIDs.count == 1,
      let endedID = input.endedIDs.first,
      let history = session.histories[endedID],
      session.activeIDs.count == session.maxContactCount - 1,
      let selectedIndex = Self.fingerIndex(
        of: history,
        restingOn: session.activeIDs,
        in: session
      )
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
    let hand = Self.orderedHand(
      including: history,
      restingOn: pending.anchorIDs,
      in: session
    )
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
      return spacingMatches(trigger.tapSpacing, hand: hand, selectedID: history.id)
    }) else { return [] }

    if let lastEmittedAt = state.lastEmittedAt,
      session.lastTimestamp - lastEmittedAt < Self.repeatCooldown
    {
      return []
    }
    state.lastEmittedAt = session.lastTimestamp

    return [TrackpadRecognizedGesture(rule: rule, isDiscrete: true)]
  }

  /// The hand on the trackpad right now — the finger doing the tapping plus the ones
  /// resting — ordered left to right by where each contact landed.
  ///
  /// Read from the landings rather than from the session's opening line-up, because a
  /// finger that has already tapped comes back under a new identity. Asking the session's
  /// first contacts to place it yields nothing, and a lift that cannot be numbered cannot
  /// arm.
  private static func orderedHand(
    including tapping: TrackpadContactHistory,
    restingOn anchorIDs: Set<Int32>,
    in session: TrackpadSessionSnapshot
  ) -> [TrackpadContactHistory] {
    ([tapping] + anchorIDs.compactMap { session.histories[$0] }).sorted {
      if $0.start.x == $1.start.x { return $0.id < $1.id }
      return $0.start.x < $1.start.x
    }
  }

  private static func fingerIndex(
    of lifted: TrackpadContactHistory,
    restingOn anchorIDs: Set<Int32>,
    in session: TrackpadSessionSnapshot
  ) -> Int? {
    orderedHand(including: lifted, restingOn: anchorIDs, in: session)
      .firstIndex { $0.id == lifted.id }
  }

  private func spacingMatches(
    _ spacing: TrackpadTapSpacing,
    hand: [TrackpadContactHistory],
    selectedID: Int32
  ) -> Bool {
    guard let selected = hand.first(where: { $0.id == selectedID }) else { return false }
    let nearest = hand.filter { $0.id != selectedID }
      .map { selected.start.distance(to: $0.start) }
      .min() ?? 0
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
  /// The two fingers walking the corridor would otherwise drag the cursor across the screen
  /// for the length of the adjustment.
  static let freezesPointer = true
  static let supportedFingerCounts = requiredContactCount...requiredContactCount

  private static let requiredContactCount = 2
  private static let minimumStep = 0.004
  private static let cooldown: TimeInterval = 0.035
  /// Only has to keep one emission from carrying an unbounded backlog. How far the value
  /// may move in a single step is the executor's ceiling, not this one, so this can be
  /// loose enough that a fast flick drains within a couple of cooldowns instead of
  /// trailing the fingers.
  /// Capped so the factory preset's largest burst (steps x minimum distance) stays inside
  /// the executor's 0.2 per-emission clamp; 12 x 0.018 = 0.216 silently truncated travel,
  /// which is exactly what travel-faithful adjustment is meant to rule out.
  static let maximumStepsPerFrame = 11

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
      // The hand has to have started at the edge and still be there. Judged over both
      // fingers together rather than one at a time, so the finger further in is measured
      // against its partner's reach instead of having to sit in the corridor itself.
      guard
        TrackpadGeometry.edgeAdmits(
          trigger.edge,
          points: activeHistories.map { $0.history.start },
          width: input.edgeWidth
        ),
        TrackpadGeometry.edgeAdmits(
          trigger.edge,
          points: activeHistories.map { $0.contact.position },
          width: TrackpadGeometry.edgeCorridorWidth(input.edgeWidth, expanded: true)
        )
      else {
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
          continuousDelta: Double(signedSteps),
          continuousTravel: Double(signedSteps) * threshold * input.sensitivity
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

// MARK: - Anchored slide

/// A hand rests on the pad and one nominated finger slides along an axis while the rest
/// hold still, quantized into repeated steps for as long as that posture lasts.
///
/// The anchors are the whole gesture. Fingers that all travel together are a two-finger
/// scroll, so a rule whose anchor tolerance is looser than its step size cannot tell the
/// two apart — which is why the shipped preset keeps the step comfortably the larger of
/// the two, and why the editor says so.
final class TrackpadAnchoredSlideRecognizer: TrackpadGestureRecognizer {
  static let kind = TrackpadGestureKind.anchoredSlide
  static let suppression = TrackpadInputSuppressionNeed.scrollWheel
  /// Fingers resting still and fingers about to be still look identical in a raw frame, so
  /// there is no geometry to arm from: the first step is what takes native scrolling.
  static let suppressionOwnership = TrackpadInputSuppressionOwnership.activeSession
  /// The sliding finger would otherwise drag the cursor across the screen for the length of
  /// the adjustment, exactly as the two edge fingers do.
  static let freezesPointer = true
  /// A fifth contact is a resting hand, not anchors plus one finger doing the work.
  static let supportedFingerCounts = 2...4

  private static let minimumStep = 0.004
  private static let cooldown: TimeInterval = 0.035
  /// One finger's travel between two frames, so a frame that arrives late cannot honestly
  /// have covered much ground; a tighter cap than the edge family's keeps a dropped frame
  /// from lurching the value.
  static let maximumStepsPerFrame = 4

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
    guard Self.supportedFingerCounts.contains(session.maxContactCount) else { return [] }
    let slideRules = input.eligibleRules.filter {
      $0.trigger.kind == Self.kind && $0.trigger.fingerCount == session.maxContactCount
    }
    guard !slideRules.isEmpty else { return [] }

    // Left to right by where each finger landed, over the contacts that are down right now.
    // A neighbour that lifts and comes back is a tip tap, not the end of this gesture, so
    // the numbering is re-read every frame rather than latched for the session.
    let landed = input.activeContacts.compactMap {
      contact -> (contact: TrackpadContact, history: TrackpadContactHistory)? in
      guard let history = session.histories[contact.id] else { return nil }
      return (contact, history)
    }.sorted {
      if $0.history.start.x == $1.history.start.x { return $0.contact.id < $1.contact.id }
      return $0.history.start.x < $1.history.start.x
    }
    // A posture that is momentarily short a finger only suspends the gesture. Forgetting
    // where the slider was is what keeps the frame it returns on from counting the gap as
    // travel.
    guard landed.count == session.maxContactCount else {
      state.lastPositions.removeAll()
      return []
    }

    var gestures: [TrackpadRecognizedGesture] = []
    for rule in slideRules {
      guard !state.cancelledRuleIDs.contains(rule.id) else { continue }
      let trigger = rule.trigger.normalized
      guard landed.indices.contains(trigger.selectedFingerIndex) else { continue }
      let selected = landed[trigger.selectedFingerIndex]
      let anchorsHeld = landed.enumerated().allSatisfy { index, entry in
        index == trigger.selectedFingerIndex || entry.history.maxTravel <= trigger.movementTolerance
      }
      // An anchor that has already wandered cannot come back: whatever the hand is doing,
      // it stopped being this gesture, and resuming would let a drifting scroll finish the
      // adjustment it started.
      guard anchorsHeld else {
        state.cancelledRuleIDs.insert(rule.id)
        state.remainders.removeValue(forKey: rule.id)
        state.lastPositions.removeValue(forKey: rule.id)
        continue
      }

      guard let previousPosition = state.lastPositions[rule.id] else {
        state.lastPositions[rule.id] = selected.contact.position
        continue
      }
      state.lastPositions[rule.id] = selected.contact.position
      let isVertical = trigger.slideAxis == .vertical
      let delta = isVertical
        ? selected.contact.position.y - previousPosition.y
        : selected.contact.position.x - previousPosition.x
      var remainder = state.remainders[rule.id, default: 0]
      // Turning around is an instruction, not a correction. Whatever the finger was still
      // owed in the old direction is dropped, so the first step back arrives as soon as the
      // finger has earned it rather than after it has paid off the backlog.
      if delta != 0, remainder != 0, (delta > 0) != (remainder > 0) { remainder = 0 }
      remainder += delta
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
            vertical: isVertical
          ),
          continuousDelta: Double(signedSteps),
          continuousTravel: Double(signedSteps) * threshold * input.sensitivity
        )
      )
      break
    }
    return gestures
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
