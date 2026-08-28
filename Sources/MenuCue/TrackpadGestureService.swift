import AppKit
import ApplicationServices
import Combine
import Foundation

enum TrackpadInputSuppressionStatus: Equatable {
  case disabled
  case active
  case requiresAccessibility
  case unavailable(reason: String)
}

enum TrackpadClickSuppressionDirective: Equatable {
  case none
  case arm
  case complete
  case cancel
}

/// Pure, per-device candidate state for the opt-in click suppressor. It arms only when
/// the current raw contacts can satisfy an enabled, scoped ordinary contact-tap rule.
struct TrackpadClickSuppressionPolicy {
  private static let maximumCandidateDuration: TimeInterval = 0.18
  private static let movementTolerance = 0.03

  private struct Candidate {
    let contactIDs: Set<Int32>
    let startingPositions: [Int32: TrackpadPoint]
    let startedAt: TimeInterval
  }

  private enum DeviceState {
    case candidate(Candidate)
    case cancelledUntilContactsEnd
  }

  private var states: [UInt64: DeviceState] = [:]

  /// This asks the shared matcher only about the predicates known at raw-frame time. The
  /// engine remains the final authority at completion, before buffered clicks are dropped.
  func shouldArm(
    frame: TrackpadFrame,
    settings: TrackpadGestureSettings,
    context: TrackpadGestureContext
  ) -> Bool {
    guard settings.isEnabled else { return false }
    let contacts = Self.candidateContacts(in: frame)
    guard (2...5).contains(contacts.count), Set(contacts.map(\.id)).count == contacts.count else {
      return false
    }
    let point = TrackpadGeometry.centroid(contacts.map(\.position))
    return !TrackpadRuleMatcher.eligibleRules(
      settings.rules,
      context: TrackpadRuleContext(
        bundleIdentifier: context.bundleIdentifier,
        modifiers: context.modifiers,
        isBuiltIn: frame.isBuiltIn
      )
    ) { rule in
      let trigger = rule.trigger.normalized
      return trigger.kind == .contact
        && trigger.contactGesture == .tap
        && trigger.fingerCount == contacts.count
        && TrackpadGeometry.regionMatches(trigger.region, point: point)
    }.isEmpty
  }

  mutating func consume(
    frame: TrackpadFrame,
    isEnabled: Bool,
    shouldArm: Bool
  ) -> TrackpadClickSuppressionDirective {
    guard isEnabled else {
      let shouldCancel = !states.isEmpty
      reset()
      return shouldCancel ? .cancel : .none
    }

    let activeContacts = Self.candidateContacts(in: frame)
    guard !activeContacts.isEmpty else {
      guard let prior = states.removeValue(forKey: frame.deviceID) else { return .none }
      guard case .candidate(let candidate) = prior else { return .none }
      let endedCandidateContacts = frame.contacts.filter { candidate.contactIDs.contains($0.id) }
      let stayedWithinTolerance = endedCandidateContacts.allSatisfy { contact in
        guard let start = candidate.startingPositions[contact.id] else { return false }
        return start.distance(to: contact.position) <= Self.movementTolerance
      }
      let completedInTime = frame.timestamp >= candidate.startedAt
        && frame.timestamp - candidate.startedAt <= Self.maximumCandidateDuration
      return stayedWithinTolerance && completedInTime ? .complete : .cancel
    }

    if case .cancelledUntilContactsEnd? = states[frame.deviceID] {
      return .none
    }

    guard (2...5).contains(activeContacts.count), shouldArm else {
      guard let prior = states[frame.deviceID] else {
        states[frame.deviceID] = .cancelledUntilContactsEnd
        return .none
      }
      if case .candidate(_) = prior {
        states[frame.deviceID] = .cancelledUntilContactsEnd
        return .cancel
      }
      return .none
    }

    let contactIDs = Set(activeContacts.map(\.id))
    guard contactIDs.count == activeContacts.count else {
      if let prior = states[frame.deviceID], case .candidate(_) = prior {
        states[frame.deviceID] = .cancelledUntilContactsEnd
        return .cancel
      }
      states[frame.deviceID] = .cancelledUntilContactsEnd
      return .none
    }

    guard let state = states[frame.deviceID] else {
      states[frame.deviceID] = .candidate(
        Candidate(
          contactIDs: contactIDs,
          startingPositions: Dictionary(
            uniqueKeysWithValues: activeContacts.map { ($0.id, $0.position) }
          ),
          startedAt: frame.timestamp
        )
      )
      return .arm
    }

    guard case .candidate(let candidate) = state,
      candidate.contactIDs == contactIDs,
      frame.timestamp >= candidate.startedAt,
      frame.timestamp - candidate.startedAt <= Self.maximumCandidateDuration,
      activeContacts.allSatisfy({ contact in
        guard let start = candidate.startingPositions[contact.id] else { return false }
        return start.distance(to: contact.position) <= Self.movementTolerance
      })
    else {
      states[frame.deviceID] = .cancelledUntilContactsEnd
      return .cancel
    }
    return .none
  }

  mutating func reset() {
    states.removeAll()
  }

  mutating func reset(deviceID: UInt64) {
    states.removeValue(forKey: deviceID)
  }

  mutating func invalidate(deviceID: UInt64) {
    states[deviceID] = .cancelledUntilContactsEnd
  }

  private static func candidateContacts(in frame: TrackpadFrame) -> [TrackpadContact] {
    frame.contacts.filter { contact in
      switch contact.state {
      case .make, .begin, .touch, .hold: return true
      case .unknown, .hover, .breakContact, .out: return false
      }
    }
  }
}

/// What the scroll tap should be doing, from whichever ownership path decided it.
struct TrackpadScrollSuppressionDecision: Equatable {
  let isSuppressing: Bool
  let drainsMomentum: Bool

  /// Two ownership paths, one tap: either may suppress, and a drain only survives if
  /// nothing is still holding the trackpad.
  func merged(with other: TrackpadScrollSuppressionDecision) -> TrackpadScrollSuppressionDecision {
    let isSuppressing = self.isSuppressing || other.isSuppressing
    return TrackpadScrollSuppressionDecision(
      isSuppressing: isSuppressing,
      drainsMomentum: (drainsMomentum || other.drainsMomentum) && !isSuppressing
    )
  }
}

/// Native-scroll ownership for a family the raw frames cannot announce in advance. Its own
/// first result takes the trackpad and holds it until that device's contacts end — the same
/// lifetime the pointer freeze uses, for the same reason: until the gesture happens, it
/// looks exactly like ordinary movement.
struct TrackpadSessionScrollSuppressionPolicy {
  private var owningDeviceID: UInt64?

  var isSuppressing: Bool { owningDeviceID != nil }

  @discardableResult
  mutating func consume(
    deviceID: UInt64,
    claims: Bool,
    hasContacts: Bool
  ) -> TrackpadScrollSuppressionDecision {
    if claims { owningDeviceID = deviceID }
    guard owningDeviceID == deviceID else { return decision(drainsMomentum: false) }
    guard hasContacts else {
      owningDeviceID = nil
      // The gesture is over but its scrolling is not: macOS keeps sending momentum for a
      // moment after the fingers leave, which is the tail this drains.
      return TrackpadScrollSuppressionDecision(isSuppressing: false, drainsMomentum: true)
    }
    return decision(drainsMomentum: false)
  }

  /// For every path that abandons a session without a final frame. Without it a stale owner
  /// would go on swallowing the user's scrolling with no gesture left to justify it.
  @discardableResult
  mutating func reset(deviceID: UInt64? = nil) -> TrackpadScrollSuppressionDecision {
    if deviceID == nil || deviceID == owningDeviceID { owningDeviceID = nil }
    return decision(drainsMomentum: false)
  }

  private func decision(drainsMomentum: Bool) -> TrackpadScrollSuppressionDecision {
    TrackpadScrollSuppressionDecision(
      isSuppressing: isSuppressing,
      drainsMomentum: drainsMomentum
    )
  }
}

enum TrackpadMatchDispatchPolicy {
  /// A gesture that only works because native scrolling is being consumed may act only
  /// while that suppression is actually in place. For a family armed from the raw frames
  /// that means the service has to have granted it already; a family that takes the
  /// trackpad with its own first result is granting it here, in this result.
  static func shouldDispatch(
    _ match: TrackpadGestureMatch,
    edgeGestureOwned: Bool
  ) -> Bool {
    match.suppressionNeed != .scrollWheel || edgeGestureOwned || match.claimsScrollSuppression
  }
}

struct TrackpadMomentumDrainPolicy {
  private(set) var deadline: TimeInterval = 0

  mutating func update(
    active: Bool,
    startsDrain: Bool,
    now: TimeInterval,
    duration: TimeInterval
  ) {
    if active {
      deadline = 0
    } else if startsDrain {
      deadline = max(deadline, now + duration)
    }
  }

  mutating func cancel() {
    deadline = 0
  }

  mutating func shouldSuppress(
    momentumPhase: Int64,
    scrollPhase: Int64,
    now: TimeInterval
  ) -> Bool {
    let shouldSuppress = momentumPhase != 0 && now <= deadline
    if momentumPhase == 0,
      scrollPhase == Int64(NSEvent.Phase.began.rawValue)
    {
      deadline = 0
    }
    return shouldSuppress
  }
}

/// Pure coordination state for native-scroll suppression during a configured edge gesture.
/// A malformed sequence or concurrent device latches every involved device open until its
/// contacts end, because a global scroll event does not expose its source trackpad.
struct TrackpadEdgeScrollSuppressionPolicy {
  private struct Session {
    var contactIDs: Set<Int32>
    var edges: [TrackpadEdge]
  }

  private enum DeviceState {
    case candidate(Session)
    case owner(Session)
    case blockedUntilContactsEnd
  }

  private var states: [UInt64: DeviceState] = [:]
  private(set) var isSuppressing = false

  @discardableResult
  mutating func consume(
    frame: TrackpadFrame,
    settings: TrackpadGestureSettings,
    context: TrackpadGestureContext
  ) -> TrackpadScrollSuppressionDecision {
    let contacts = frame.contacts.filter(\.state.isTouching)
    let frameContactIDs = frame.contacts.map(\.id)
    let contactIDs = Set(contacts.map(\.id))
    let hasUniqueFrameContactIDs = Set(frameContactIDs).count == frameContactIDs.count
    let ownerEndedNaturally: Bool
    if hasUniqueFrameContactIDs,
      let state = states[frame.deviceID],
      case .owner(let session) = state,
      Set(frameContactIDs).isSubset(of: session.contactIDs)
    {
      ownerEndedNaturally = contactIDs.count < session.contactIDs.count
        && contactIDs.isSubset(of: session.contactIDs)
    } else {
      ownerEndedNaturally = false
    }

    if !hasUniqueFrameContactIDs {
      states[frame.deviceID] = .blockedUntilContactsEnd
    } else if contacts.isEmpty {
      states.removeValue(forKey: frame.deviceID)
    } else if let state = states[frame.deviceID] {
      switch state {
      case .blockedUntilContactsEnd:
        break
      case .candidate(var session):
        if contacts.count == 1,
          contactIDs == session.contactIDs,
          Set(frameContactIDs).isSubset(of: session.contactIDs)
        {
          let eligibleEdges = Self.matchingEdges(
            frame: frame,
            points: contacts.map(\.position),
            settings: settings,
            context: context,
            useExpandedCorridor: true
          )
          session.edges = session.edges.filter { eligibleEdges.contains($0) }
          states[frame.deviceID] = session.edges.isEmpty
            ? .blockedUntilContactsEnd
            : .candidate(session)
        } else if contacts.count == 2,
          session.contactIDs.isSubset(of: contactIDs),
          Set(frameContactIDs).isSubset(of: contactIDs)
        {
          let heldPoints = contacts.filter { session.contactIDs.contains($0.id) }.map(\.position)
          let heldEdges = Self.matchingEdges(
            frame: frame,
            points: heldPoints,
            settings: settings,
            context: context,
            useExpandedCorridor: true
          )
          // The finger that just landed is judged as part of the pair, never on its own:
          // the whole point of the second finger is that it may sit outside the corridor,
          // so asking it to satisfy the corridor by itself would refuse every posture but
          // the stacked one.
          let pairEdges = Self.matchingEdges(
            frame: frame,
            points: contacts.map(\.position),
            settings: settings,
            context: context,
            useExpandedCorridor: false
          )
          session.contactIDs = contactIDs
          session.edges = session.edges.filter {
            heldEdges.contains($0) && pairEdges.contains($0)
          }
          states[frame.deviceID] = session.edges.isEmpty
            ? .blockedUntilContactsEnd
            : .owner(session)
        } else {
          states[frame.deviceID] = .blockedUntilContactsEnd
        }
      case .owner(var session):
        guard contacts.count == 2,
          contactIDs == session.contactIDs,
          Set(frameContactIDs).isSubset(of: session.contactIDs)
        else {
          states[frame.deviceID] = .blockedUntilContactsEnd
          break
        }
        let eligibleEdges = Self.matchingEdges(
          frame: frame,
          points: contacts.map(\.position),
          settings: settings,
          context: context,
          useExpandedCorridor: true
        )
        session.edges = session.edges.filter { eligibleEdges.contains($0) }
        states[frame.deviceID] = session.edges.isEmpty
          ? .blockedUntilContactsEnd
          : .owner(session)
      }
    } else if Set(frameContactIDs) == contactIDs {
      let edges = Self.matchingEdges(
        frame: frame,
        points: contacts.map(\.position),
        settings: settings,
        context: context,
        useExpandedCorridor: false
      )
      if edges.isEmpty || contacts.count > 2 {
        states[frame.deviceID] = .blockedUntilContactsEnd
      } else if contacts.count == 1 {
        states[frame.deviceID] = .candidate(
          Session(contactIDs: contactIDs, edges: edges)
        )
      } else if contacts.count == 2 {
        states[frame.deviceID] = .owner(
          Session(contactIDs: contactIDs, edges: edges)
        )
      } else {
        states[frame.deviceID] = .blockedUntilContactsEnd
      }
    } else {
      states[frame.deviceID] = .blockedUntilContactsEnd
    }

    if states.count > 1 {
      for deviceID in Array(states.keys) {
        states[deviceID] = .blockedUntilContactsEnd
      }
    }
    return updateSuppressionState(drainsMomentum: ownerEndedNaturally)
  }

  @discardableResult
  mutating func invalidate(deviceID: UInt64) -> TrackpadScrollSuppressionDecision {
    states[deviceID] = .blockedUntilContactsEnd
    if states.count > 1 {
      for activeDeviceID in Array(states.keys) {
        states[activeDeviceID] = .blockedUntilContactsEnd
      }
    }
    return updateSuppressionState(drainsMomentum: false)
  }

  @discardableResult
  mutating func reset(deviceID: UInt64? = nil) -> TrackpadScrollSuppressionDecision {
    if let deviceID {
      states.removeValue(forKey: deviceID)
    } else {
      states.removeAll()
    }
    return updateSuppressionState(drainsMomentum: false)
  }

  private mutating func updateSuppressionState(
    drainsMomentum: Bool
  ) -> TrackpadScrollSuppressionDecision {
    if states.count == 1, let state = states.values.first, case .owner = state {
      isSuppressing = true
    } else {
      isSuppressing = false
    }
    return TrackpadScrollSuppressionDecision(
      isSuppressing: isSuppressing,
      drainsMomentum: drainsMomentum && !isSuppressing
    )
  }

  private static func matchingEdges(
    frame: TrackpadFrame,
    points: [TrackpadPoint],
    settings: TrackpadGestureSettings,
    context: TrackpadGestureContext,
    useExpandedCorridor: Bool
  ) -> [TrackpadEdge] {
    guard settings.isEnabled, !points.isEmpty else { return [] }
    let width = TrackpadGeometry.edgeCorridorWidth(
      settings.edgeWidth,
      expanded: useExpandedCorridor
    )
    return TrackpadRuleMatcher.eligibleRules(
      settings.rules,
      context: TrackpadRuleContext(
        bundleIdentifier: context.bundleIdentifier,
        modifiers: context.modifiers,
        isBuiltIn: frame.isBuiltIn
      )
    ) { rule in
      let trigger = rule.trigger.normalized
      return trigger.kind == .edgeContinuous
        && trigger.fingerCount == 2
        && TrackpadGeometry.edgeAdmits(trigger.edge, points: points, width: width)
    }.map(\.trigger.edge)
  }
}

/// A narrowly scoped opt-in event tap. It never observes trackpad contacts and only
/// consumes the down/up pair armed by a current raw multi-contact candidate.
private final class TrackpadClickSuppressor {
  private static let armWindow: TimeInterval = 0.18
  private static let replayMarker: Int64 = 0x4D435450

  private let accessibilityPermissionRequester: AccessibilityPermissionRequesting

  init(accessibilityPermissionRequester: AccessibilityPermissionRequesting) {
    self.accessibilityPermissionRequester = accessibilityPermissionRequester
  }

  private enum State {
    case idle
    case tentative(deadline: TimeInterval, token: UInt64, bufferedEvents: [CGEvent])
    case confirmed(deadline: TimeInterval, token: UInt64, suppressingMouseUp: Bool)
    case replaying(deadline: TimeInterval, token: UInt64, bufferedEvents: [CGEvent])
  }

  private let lock = NSLock()
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var isRequested = false
  private var state: State = .idle
  private var nextToken: UInt64 = 0

  private(set) var status: TrackpadInputSuppressionStatus = .disabled {
    didSet {
      guard oldValue != status else { return }
      stateHandler?(status)
    }
  }

  var stateHandler: ((TrackpadInputSuppressionStatus) -> Void)?

  deinit {
    stop()
  }

  /// This must be called on the main run loop because a CGEvent tap is installed there.
  /// It intentionally uses the non-prompting trust check: merely enabling trackpad
  /// observation must not cause an Accessibility prompt.
  func apply(isEnabled: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    isRequested = isEnabled
    guard isEnabled else {
      cancel()
      stopResources()
      transition(to: .disabled)
      return
    }

    guard accessibilityPermissionRequester.status == .granted else {
      cancel()
      stopResources()
      transition(to: .requiresAccessibility)
      return
    }

    guard eventTap == nil else {
      transition(to: .active)
      return
    }

    let mask =
      CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
      | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let suppressor = Unmanaged<TrackpadClickSuppressor>
          .fromOpaque(userInfo)
          .takeUnretainedValue()
        return suppressor.handle(type: type, event: event)
      },
      userInfo: userInfo
    ) else {
      transition(to: .unavailable(reason: "macOS could not create the click-suppression event tap."))
      return
    }

    self.eventTap = eventTap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    transition(to: .active)
  }

  /// Explicit user intent is the only path that can request the Accessibility prompt.
  func requestAccessibility() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard accessibilityPermissionRequester.requestAccess() else {
      transition(to: .requiresAccessibility)
      return
    }
    apply(isEnabled: isRequested)
  }

  func retry() {
    dispatchPrecondition(condition: .onQueue(.main))
    apply(isEnabled: isRequested)
  }

  func armTentatively() {
    performOnMainSynchronously { [self] in
      let events: [CGEvent]
      let token: UInt64
      lock.lock()
      events = bufferedEventsLocked()
      nextToken &+= 1
      token = nextToken
      state = .tentative(
        deadline: ProcessInfo.processInfo.systemUptime + Self.armWindow,
        token: token,
        bufferedEvents: []
      )
      lock.unlock()
      replay(events)
      scheduleExpiry(token: token)
    }
  }

  /// Confirms only after the engine emits an ordinary contact-tap match for the same
  /// raw contact sequence. Buffered tentative events are deliberately discarded.
  func confirm() {
    performOnMainSynchronously { [self] in
      let events: [CGEvent]
      lock.lock()
      guard case .tentative(let deadline, let token, let bufferedEvents) = state else {
        lock.unlock()
        return
      }
      if ProcessInfo.processInfo.systemUptime > deadline {
        events = bufferedEvents
        state = .idle
        nextToken &+= 1
      } else {
        events = []
        let hasBufferedDown = bufferedEvents.contains { $0.type == .leftMouseDown }
        let hasBufferedUp = bufferedEvents.contains { $0.type == .leftMouseUp }
        if hasBufferedDown && hasBufferedUp {
          state = .idle
          nextToken &+= 1
        } else {
          state = .confirmed(
            deadline: deadline,
            token: token,
            suppressingMouseUp: hasBufferedDown
          )
        }
      }
      lock.unlock()
      replay(events)
    }
  }

  /// Cancels the transaction without exposing idle between a buffered down and its
  /// physical up. The event-tap run loop completes or balances the pair in order.
  func cancel() {
    performOnMainSynchronously { [self] in
      lock.lock()
      let events = bufferedEventsLocked()
      let hasDown = events.contains { $0.type == .leftMouseDown }
      let hasUp = events.contains { $0.type == .leftMouseUp }
      nextToken &+= 1
      let token = nextToken
      if hasDown && !hasUp {
        state = .replaying(
          deadline: ProcessInfo.processInfo.systemUptime + Self.armWindow,
          token: token,
          bufferedEvents: events
        )
        lock.unlock()
        scheduleExpiry(token: token)
        return
      }
      state = .idle
      lock.unlock()
      replay(events)
    }
  }

  private func performOnMainSynchronously(_ operation: () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.sync(execute: operation)
    }
  }

  func stop() {
    cancel()
    performOnMainSynchronously { [self] in
      finishReplayImmediately()
      stopResources()
    }
  }

  private func finishReplayImmediately() {
    lock.lock()
    guard case .replaying(_, _, let events) = state else {
      lock.unlock()
      return
    }
    state = .idle
    nextToken &+= 1
    lock.unlock()
    replay(events)
  }

  private func stopResources() {
    dispatchPrecondition(condition: .onQueue(.main))
    finishReplayImmediately()
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    eventTap = nil
    runLoopSource = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
      return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      cancel()
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    switch state {
    case .idle:
      lock.unlock()
      return Unmanaged.passUnretained(event)

    case .tentative(let deadline, let token, var bufferedEvents):
      guard now <= deadline else {
        state = .idle
        nextToken &+= 1
        lock.unlock()
        replay(bufferedEvents)
        return Unmanaged.passUnretained(event)
      }
      if type == .leftMouseDown,
        !bufferedEvents.contains(where: { $0.type == .leftMouseDown }),
        let copy = event.copy()
      {
        bufferedEvents.append(copy)
        state = .tentative(deadline: deadline, token: token, bufferedEvents: bufferedEvents)
        lock.unlock()
        return nil
      }
      if type == .leftMouseUp,
        bufferedEvents.contains(where: { $0.type == .leftMouseDown }),
        !bufferedEvents.contains(where: { $0.type == .leftMouseUp }),
        let copy = event.copy()
      {
        bufferedEvents.append(copy)
        state = .tentative(deadline: deadline, token: token, bufferedEvents: bufferedEvents)
        lock.unlock()
        return nil
      }
      lock.unlock()
      return Unmanaged.passUnretained(event)

    case .replaying(let deadline, _, var bufferedEvents):
      if type == .leftMouseUp,
        bufferedEvents.contains(where: { $0.type == .leftMouseDown }),
        let copy = event.copy()
      {
        bufferedEvents.append(copy)
        state = .idle
        nextToken &+= 1
        lock.unlock()
        replay(bufferedEvents)
        return nil
      }
      if type == .leftMouseDown || now > deadline {
        state = .idle
        nextToken &+= 1
        lock.unlock()
        replay(bufferedEvents)
        return Unmanaged.passUnretained(event)
      }
      lock.unlock()
      return Unmanaged.passUnretained(event)

    case .confirmed(let deadline, let token, let suppressingMouseUp):
      guard now <= deadline else {
        state = .idle
        nextToken &+= 1
        lock.unlock()
        return Unmanaged.passUnretained(event)
      }
      if type == .leftMouseDown {
        state = .confirmed(deadline: deadline, token: token, suppressingMouseUp: true)
        lock.unlock()
        return nil
      }
      if type == .leftMouseUp, suppressingMouseUp {
        state = .idle
        nextToken &+= 1
        lock.unlock()
        return nil
      }
      lock.unlock()
      return Unmanaged.passUnretained(event)
    }
  }

  private func scheduleExpiry(token: UInt64) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.armWindow) { [weak self] in
      self?.expire(token: token)
    }
  }

  private func expire(token: UInt64) {
    let events: [CGEvent]
    lock.lock()
    switch state {
    case .tentative(_, let activeToken, let bufferedEvents) where activeToken == token:
      events = bufferedEvents
      state = .idle
      nextToken &+= 1
    case .confirmed(_, let activeToken, _) where activeToken == token:
      events = []
      state = .idle
      nextToken &+= 1
    case .replaying(_, let activeToken, let bufferedEvents) where activeToken == token:
      events = bufferedEvents
      state = .idle
      nextToken &+= 1
    default:
      events = []
    }
    lock.unlock()
    replay(events)
  }

  private func bufferedEventsLocked() -> [CGEvent] {
    switch state {
    case .tentative(_, _, let events), .replaying(_, _, let events):
      return events
    case .idle, .confirmed:
      return []
    }
  }

  private func replay(_ events: [CGEvent]) {
    let balancedEvents = balancedReplayEvents(events)
    guard !balancedEvents.isEmpty else { return }
    let replay = {
      for event in balancedEvents {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cghidEventTap)
      }
    }
    if Thread.isMainThread {
      replay()
    } else {
      DispatchQueue.main.sync(execute: replay)
    }
  }

  private func balancedReplayEvents(_ events: [CGEvent]) -> [CGEvent] {
    guard let mouseDown = events.first(where: { $0.type == .leftMouseDown }),
      !events.contains(where: { $0.type == .leftMouseUp }),
      let mouseUp = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: mouseDown.location,
        mouseButton: .left
      )
    else { return events }
    mouseUp.flags = mouseDown.flags
    return events + [mouseUp]
  }

  private func transition(to nextStatus: TrackpadInputSuppressionStatus) {
    status = nextStatus
  }
}

/// Consumes only native scroll-wheel events emitted while a raw edge gesture owns the
/// trackpad. A short momentum drain prevents the recognized gesture from scrolling after
/// lift-off, while a new non-momentum scroll fails open immediately.
private final class TrackpadEdgeScrollSuppressor {
  private static let momentumDrainDuration: TimeInterval = 0.3

  private let accessibilityPermissionRequester: AccessibilityPermissionRequesting
  private let lock = NSLock()
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var isRequested = false
  private var isGestureActive = false
  private var momentumDrainPolicy = TrackpadMomentumDrainPolicy()

  private(set) var status: TrackpadInputSuppressionStatus = .disabled {
    didSet {
      guard oldValue != status else { return }
      stateHandler?(status)
    }
  }

  var stateHandler: ((TrackpadInputSuppressionStatus) -> Void)?

  init(accessibilityPermissionRequester: AccessibilityPermissionRequesting) {
    self.accessibilityPermissionRequester = accessibilityPermissionRequester
  }

  deinit {
    stop()
  }

  func apply(isEnabled: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    isRequested = isEnabled
    guard isEnabled else {
      setGestureActive(false, cancelMomentumDrain: true)
      stopResources()
      transition(to: .disabled)
      return
    }
    guard accessibilityPermissionRequester.status == .granted else {
      setGestureActive(false, cancelMomentumDrain: true)
      stopResources()
      transition(to: .requiresAccessibility)
      return
    }
    guard eventTap == nil else {
      transition(to: .active)
      return
    }

    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let suppressor = Unmanaged<TrackpadEdgeScrollSuppressor>
          .fromOpaque(userInfo)
          .takeUnretainedValue()
        return suppressor.handle(type: type, event: event)
      },
      userInfo: userInfo
    ) else {
      transition(to: .unavailable(reason: "macOS could not create the edge-scroll event tap."))
      return
    }

    self.eventTap = eventTap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    transition(to: .active)
  }

  func requestAccessibility() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard accessibilityPermissionRequester.requestAccess() else {
      transition(to: .requiresAccessibility)
      return
    }
    apply(isEnabled: isRequested)
  }

  func retry() {
    dispatchPrecondition(condition: .onQueue(.main))
    apply(isEnabled: isRequested)
  }

  func setGestureActive(
    _ active: Bool,
    drainMomentum: Bool = false,
    cancelMomentumDrain: Bool = false
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    isGestureActive = active
    if cancelMomentumDrain {
      momentumDrainPolicy.cancel()
    }
    momentumDrainPolicy.update(
      active: active,
      startsDrain: drainMomentum,
      now: now,
      duration: Self.momentumDrainDuration
    )
    lock.unlock()
  }

  func stop() {
    performOnMainSynchronously { [self] in
      setGestureActive(false, cancelMomentumDrain: true)
      stopResources()
    }
  }

  private func performOnMainSynchronously(_ operation: () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.sync(execute: operation)
    }
  }

  private func stopResources() {
    dispatchPrecondition(condition: .onQueue(.main))
    lock.lock()
    isGestureActive = false
    momentumDrainPolicy.cancel()
    lock.unlock()
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    eventTap = nil
    runLoopSource = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      setGestureActive(false, cancelMomentumDrain: true)
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    let now = ProcessInfo.processInfo.systemUptime
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    lock.lock()
    let shouldSuppress = isGestureActive
      || momentumDrainPolicy.shouldSuppress(
        momentumPhase: momentumPhase,
        scrollPhase: scrollPhase,
        now: now
      )
    lock.unlock()
    return shouldSuppress ? nil : Unmanaged.passUnretained(event)
  }

  private func transition(to nextStatus: TrackpadInputSuppressionStatus) {
    status = nextStatus
  }
}

/// Long-lived owner for raw input, recognition, action dispatch, lifecycle reconciliation,
/// and bounded diagnostics. Persisted intent remains in AppSettings; this service owns only
/// observed runtime state.
final class TrackpadGestureService: ObservableObject {
  @Published private(set) var status: TrackpadRuntimeStatus = .disabled
  @Published private(set) var liveContacts: [TrackpadContact] = []
  @Published private(set) var lastRecognition: String?
  @Published private(set) var clickSuppressionStatus: TrackpadInputSuppressionStatus = .disabled
  @Published private(set) var edgeScrollSuppressionStatus: TrackpadInputSuppressionStatus = .disabled

  private let engineQueue: DispatchQueue
  private let notificationCenter: NotificationCenter
  private let workspaceNotificationCenter: NotificationCenter
  private let accessibilityPermissionRequester: AccessibilityPermissionRequesting
  private let executor: TrackpadActionExecutor
  private let clickSuppressor: TrackpadClickSuppressor
  private let edgeScrollSuppressor: TrackpadEdgeScrollSuppressor
  private let pointerFreeze: TrackpadPointerFreezeCoordinator

  private var engine: TrackpadGestureEngine
  private var activeSettings: TrackpadGestureSettings
  private var clickSuppressionPolicy = TrackpadClickSuppressionPolicy()
  private var edgeScrollSuppressionPolicy = TrackpadEdgeScrollSuppressionPolicy()
  private var sessionScrollSuppressionPolicy = TrackpadSessionScrollSuppressionPolicy()
  private var clickSuppressionOwnerDeviceID: UInt64?
  private var clickSuppressionConflictedDeviceIDs = Set<UInt64>()
  private var wakeObserver: NSObjectProtocol?
  private var sleepObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?
  private var frontmostObserver: NSObjectProtocol?
  private var lastLiveContactPublication: TimeInterval = 0
  private var livePreviewRetainCount = 0

  // Written only on the main thread, read on the engine queue for every frame.
  private let frontmostLock = NSLock()
  private var frontmostBundleIdentifier: String?
  private var hasFrontmostBundleIdentifier = false

  private lazy var source = MultitouchTrackpadSource(
    deliveryQueue: engineQueue,
    frameHandler: { [weak self] frame in
      self?.receive(frame)
    },
    invalidFrameHandler: { [weak self] deviceID, reason in
      guard let self else { return }
      self.engine.reset(deviceID: deviceID)
      self.pointerFreeze.release()
      let edgeDecision: TrackpadScrollSuppressionDecision
      switch reason {
      case .deviceRemoved:
        self.clickSuppressionPolicy.reset(deviceID: deviceID)
        self.clickSuppressionConflictedDeviceIDs.remove(deviceID)
        edgeDecision = self.edgeScrollSuppressionPolicy.reset(deviceID: deviceID)
      case .malformedFrame:
        self.clickSuppressionPolicy.invalidate(deviceID: deviceID)
        edgeDecision = self.edgeScrollSuppressionPolicy.invalidate(deviceID: deviceID)
      }
      // A device that lost its frames cannot report the lift that would have released its
      // session ownership, so this is the release.
      let scrollDecision = edgeDecision.merged(
        with: self.sessionScrollSuppressionPolicy.reset(deviceID: deviceID)
      )
      self.edgeScrollSuppressor.setGestureActive(
        scrollDecision.isSuppressing,
        drainMomentum: scrollDecision.drainsMomentum,
        cancelMomentumDrain: true
      )
      if self.clickSuppressionOwnerDeviceID == deviceID {
        self.clickSuppressionOwnerDeviceID = nil
        self.clickSuppressor.cancel()
      }
    },
    stateHandler: { [weak self] sourceState in
      self?.publish(status: Self.runtimeStatus(for: sourceState))
    }
  )

  init(
    quickActionService: QuickActionService,
    notificationCenter: NotificationCenter = .default,
    workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    accessibilityPermissionRequester: AccessibilityPermissionRequesting =
      SystemAccessibilityPermissionRequester(),
    pointerFreezer: PointerFreezing = SystemPointerFreezer()
  ) {
    let engineQueue = DispatchQueue(
      label: "com.tagzxia.app.menucue.trackpad.engine",
      qos: .userInteractive
    )
    self.engineQueue = engineQueue
    // The closure captures the queue rather than the service, so the pending watchdog can
    // never be the reason a deallocating service stays alive.
    self.pointerFreeze = TrackpadPointerFreezeCoordinator(
      freezer: pointerFreezer,
      scheduleWatchdog: { delay, body in
        engineQueue.asyncAfter(deadline: .now() + delay, execute: body)
      }
    )
    self.notificationCenter = notificationCenter
    self.workspaceNotificationCenter = workspaceNotificationCenter
    self.accessibilityPermissionRequester = accessibilityPermissionRequester
    self.executor = TrackpadActionExecutor(
      quickActionService: quickActionService,
      accessibilityPermissionRequester: accessibilityPermissionRequester
    )
    self.clickSuppressor = TrackpadClickSuppressor(
      accessibilityPermissionRequester: accessibilityPermissionRequester
    )
    self.edgeScrollSuppressor = TrackpadEdgeScrollSuppressor(
      accessibilityPermissionRequester: accessibilityPermissionRequester
    )
    self.activeSettings = .default
    self.engine = TrackpadGestureEngine(settings: .default)
    clickSuppressor.stateHandler = { [weak self] status in
      self?.publish(clickSuppressionStatus: status)
    }
    edgeScrollSuppressor.stateHandler = { [weak self] status in
      self?.publish(edgeScrollSuppressionStatus: status)
    }
  }

  deinit {
    stop()
  }

  /// Applies a complete machine-local settings snapshot. Replacing the snapshot resets
  /// recognition sessions so an old contact cannot complete a rule under new thresholds.
  func apply(settings: TrackpadGestureSettings) {
    configureLifecycleObservers(enabled: settings.isEnabled)
    configureClickSuppression(enabled: settings.isEnabled && settings.suppressesClickAfterMultiFingerTap)
    configureEdgeScrollSuppression(
      enabled: settings.isEnabled
        && TrackpadRecognizerRegistry.suppressionNeeds(for: settings.rules).contains(.scrollWheel)
    )
    engineQueue.async { [weak self] in
      guard let self else { return }
      self.activeSettings = settings
      self.engine.apply(settings: settings)
      self.engine.reset()
      self.pointerFreeze.release()
      self.clickSuppressionPolicy.reset()
      self.edgeScrollSuppressionPolicy.reset()
      self.sessionScrollSuppressionPolicy.reset()
      self.edgeScrollSuppressor.setGestureActive(false, cancelMomentumDrain: true)
      self.clickSuppressionOwnerDeviceID = nil
      self.clickSuppressionConflictedDeviceIDs.removeAll()
      self.clickSuppressor.cancel()
      if settings.isEnabled {
        self.source.start()
      } else {
        self.source.stop()
        self.publish(status: .disabled)
        self.publish(liveContacts: [])
        self.publish(lastRecognition: nil)
      }
    }
  }

  /// Re-attempts optional capabilities without changing the saved configuration.
  func retry() {
    engineQueue.async { [weak self] in
      guard let self, self.activeSettings.isEnabled else { return }
      self.engine.reset()
      self.pointerFreeze.release()
      self.clickSuppressionPolicy.reset()
      self.edgeScrollSuppressionPolicy.reset()
      self.sessionScrollSuppressionPolicy.reset()
      self.edgeScrollSuppressor.setGestureActive(false, cancelMomentumDrain: true)
      self.clickSuppressionOwnerDeviceID = nil
      self.clickSuppressionConflictedDeviceIDs.removeAll()
      self.clickSuppressor.cancel()
      self.source.retry()
      self.source.start()
    }
    runOnMain { [weak self] in
      self?.clickSuppressor.retry()
      self?.edgeScrollSuppressor.retry()
    }
  }

  func requestInputSuppressionAccessibility() {
    runOnMain { [weak self] in
      self?.clickSuppressor.requestAccessibility()
      self?.edgeScrollSuppressor.requestAccessibility()
    }
  }

  func openAccessibilitySettings() {
    WorkspaceOpener.openSettings(accessibilityPermissionRequester.accessibilitySettingsURL)
  }

  /// Whether a configured action could run right now. The rule editor asks before the
  /// gesture ever fires, so a rule that cannot work says so while it is being written
  /// rather than failing silently on the trackpad.
  func availability(for action: TrackpadGestureAction) -> ActionAvailability {
    executor.availability(for: action)
  }

  /// The same answer for a whole rule list in one pass.
  func availabilities(for actions: [TrackpadGestureAction]) -> [ActionAvailability] {
    executor.availabilities(for: actions)
  }

  func stop() {
    removeLifecycleObservers()
    // Synchronously, not on the engine queue: `deinit` and application termination both
    // land here, and by then a queued block would find `self` already gone.
    pointerFreeze.release()
    runOnMain { [weak self] in
      self?.clickSuppressor.apply(isEnabled: false)
      self?.edgeScrollSuppressor.apply(isEnabled: false)
    }
    source.stop()
    engineQueue.async { [weak self] in
      guard let self else { return }
      self.engine.reset()
      // Again, in case a frame already in flight froze the pointer after the call above.
      self.pointerFreeze.release()
      self.clickSuppressionPolicy.reset()
      self.edgeScrollSuppressionPolicy.reset()
      self.sessionScrollSuppressionPolicy.reset()
      self.edgeScrollSuppressor.setGestureActive(false, cancelMomentumDrain: true)
      self.clickSuppressionOwnerDeviceID = nil
      self.clickSuppressionConflictedDeviceIDs.removeAll()
      self.clickSuppressor.cancel()
    }
    publish(status: .disabled)
    publish(liveContacts: [])
  }

  private func receive(_ sourceFrame: TrackpadSourceFrame) {
    guard activeSettings.isEnabled else { return }
    let frame = sourceFrame.trackpadFrame
    let context = currentContext()
    let edgeDecision = edgeScrollSuppressionPolicy.consume(
      frame: frame,
      settings: activeSettings,
      context: context
    )
    let hasActiveContacts = frame.contacts.contains { $0.state.isActive }
    if !clickSuppressionConflictedDeviceIDs.isEmpty {
      if hasActiveContacts {
        clickSuppressionConflictedDeviceIDs.insert(frame.deviceID)
      } else {
        clickSuppressionConflictedDeviceIDs.remove(frame.deviceID)
      }
    }
    let hasDeviceConflict = !clickSuppressionConflictedDeviceIDs.isEmpty
    let shouldArm = !hasDeviceConflict && clickSuppressionPolicy.shouldArm(
      frame: frame,
      settings: activeSettings,
      context: context
    )
    let directive = clickSuppressionPolicy.consume(
      frame: frame,
      isEnabled: activeSettings.suppressesClickAfterMultiFingerTap,
      shouldArm: shouldArm
    )
    switch directive {
    case .none, .complete:
      break
    case .arm:
      if let owner = clickSuppressionOwnerDeviceID, owner != frame.deviceID {
        clickSuppressionPolicy.reset()
        clickSuppressionConflictedDeviceIDs.formUnion([owner, frame.deviceID])
        clickSuppressionOwnerDeviceID = nil
        clickSuppressor.cancel()
      } else {
        clickSuppressionOwnerDeviceID = frame.deviceID
        clickSuppressor.armTentatively()
      }
    case .cancel:
      if clickSuppressionOwnerDeviceID == frame.deviceID {
        clickSuppressionOwnerDeviceID = nil
        clickSuppressor.cancel()
      }
    }

    publishLiveContacts(frame.contacts)
    let matches = engine.consume(frame: frame, context: context)
    let dispatchableMatches = matches.filter {
      TrackpadMatchDispatchPolicy.shouldDispatch(
        $0,
        edgeGestureOwned: edgeDecision.isSuppressing
      )
    }
    // Told after recognition rather than before it, because the second ownership path only
    // exists once a result has claimed it. Both paths still reach the tap on the frame that
    // decided them.
    let scrollDecision = edgeDecision.merged(
      with: sessionScrollSuppressionPolicy.consume(
        deviceID: frame.deviceID,
        claims: dispatchableMatches.contains(where: \.claimsScrollSuppression),
        hasContacts: frame.contacts.contains { $0.state.isTouching }
      )
    )
    edgeScrollSuppressor.setGestureActive(
      scrollDecision.isSuppressing,
      drainMomentum: scrollDecision.drainsMomentum
    )
    // The pointer is frozen by the first continuous step, not by entry into the corridor,
    // so an ordinary two-finger scroll along an edge never loses its cursor.
    if dispatchableMatches.contains(where: \.freezesPointer) {
      pointerFreeze.beginContinuousAdjustment(deviceID: frame.deviceID)
    }
    for match in dispatchableMatches {
      handle(match)
    }
    // After the freeze decision, never before: a frame that both steps and reports its
    // contacts gone has to end released. `isTouching` is the same predicate the engine
    // uses to pick a session's contacts, so a frame that produced a step always says yes.
    pointerFreeze.observeFrame(
      deviceID: frame.deviceID,
      hasContacts: frame.contacts.contains { $0.state.isTouching }
    )
    if directive == .complete, clickSuppressionOwnerDeviceID == frame.deviceID {
      clickSuppressionOwnerDeviceID = nil
      if dispatchableMatches.contains(where: \.confirmsSuppressedClick) {
        clickSuppressor.confirm()
      } else {
        clickSuppressor.cancel()
      }
    }
  }

  /// Recognition happens on the engine queue; the action runs on the main thread and the
  /// engine does not wait for it, so a modal an action puts up cannot stall the next frame.
  private func handle(_ match: TrackpadGestureMatch) {
    publish(lastRecognition: match.ruleName)
    let feedbackHUDEnabled = activeSettings.feedbackHUDEnabled
    let hapticFeedbackEnabled = activeSettings.hapticFeedbackEnabled
    let continuous = match.continuousDelta != 0
    runOnMain { [weak self] in
      guard let self else { return }
      if match.activatesWindowUnderPointer {
        _ = self.executor.activateWindowUnderPointer()
      }
      _ = self.executor.execute(
        match.action,
        feedbackHUDEnabled: feedbackHUDEnabled,
        hapticFeedbackEnabled: hapticFeedbackEnabled,
        continuous: continuous,
        continuousTravel: match.continuousTravel
      )
    }
  }


  private func configureLifecycleObservers(enabled: Bool) {
    runOnMain { [weak self] in
      guard let self else { return }
      if enabled {
        guard self.wakeObserver == nil else { return }
        self.wakeObserver = self.workspaceNotificationCenter.addObserver(
          forName: NSWorkspace.didWakeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.handleWake()
        }
        self.sleepObserver = self.workspaceNotificationCenter.addObserver(
          forName: NSWorkspace.willSleepNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.handleSleep()
        }
        self.activationObserver = self.notificationCenter.addObserver(
          forName: NSApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.reconcileAfterActivation()
        }
        self.frontmostObserver = self.workspaceNotificationCenter.addObserver(
          forName: NSWorkspace.didActivateApplicationNotification,
          object: nil,
          queue: .main
        ) { [weak self] notification in
          let application =
            notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
          self?.primeFrontmostApplication(application?.bundleIdentifier)
        }
        // The observer is live from here on, so any activation that lands after this read
        // overwrites it rather than being lost.
        self.primeFrontmostApplication(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
      } else {
        self.removeLifecycleObservers()
      }
    }
  }

  private func removeLifecycleObservers() {
    runOnMain { [weak self] in
      guard let self else { return }
      if let wakeObserver {
        self.workspaceNotificationCenter.removeObserver(wakeObserver)
        self.wakeObserver = nil
      }
      if let sleepObserver {
        self.workspaceNotificationCenter.removeObserver(sleepObserver)
        self.sleepObserver = nil
      }
      if let activationObserver {
        self.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
      }
      if let frontmostObserver {
        self.workspaceNotificationCenter.removeObserver(frontmostObserver)
        self.frontmostObserver = nil
      }
      self.clearFrontmostApplication()
    }
  }

  private func primeFrontmostApplication(_ bundleIdentifier: String?) {
    frontmostLock.lock()
    frontmostBundleIdentifier = bundleIdentifier
    hasFrontmostBundleIdentifier = true
    frontmostLock.unlock()
  }

  private func clearFrontmostApplication() {
    frontmostLock.lock()
    frontmostBundleIdentifier = nil
    hasFrontmostBundleIdentifier = false
    frontmostLock.unlock()
  }

  private func handleWake() {
    engineQueue.async { [weak self] in
      guard let self, self.activeSettings.isEnabled else { return }
      self.engine.reset()
      self.pointerFreeze.release()
      self.clickSuppressionPolicy.reset()
      self.edgeScrollSuppressionPolicy.reset()
      self.sessionScrollSuppressionPolicy.reset()
      self.edgeScrollSuppressor.setGestureActive(false, cancelMomentumDrain: true)
      self.clickSuppressionOwnerDeviceID = nil
      self.clickSuppressionConflictedDeviceIDs.removeAll()
      self.clickSuppressor.cancel()
      self.source.start()
    }
  }

  private func handleSleep() {
    engineQueue.async { [weak self] in
      guard let self else { return }
      self.engine.reset()
      self.pointerFreeze.release()
      self.clickSuppressionPolicy.reset()
      self.edgeScrollSuppressionPolicy.reset()
      self.sessionScrollSuppressionPolicy.reset()
      self.edgeScrollSuppressor.setGestureActive(false, cancelMomentumDrain: true)
      self.clickSuppressionOwnerDeviceID = nil
      self.clickSuppressionConflictedDeviceIDs.removeAll()
      self.clickSuppressor.cancel()
      self.source.stop()
      self.publish(liveContacts: [])
    }
  }

  private func reconcileAfterActivation() {
    engineQueue.async { [weak self] in
      guard let self, self.activeSettings.isEnabled else { return }
      self.source.reconcile()
    }
    runOnMain { [weak self] in
      self?.clickSuppressor.retry()
      self?.edgeScrollSuppressor.retry()
    }
  }

  /// Balanced by the trackpad settings pane while it is on screen. Nothing else observes
  /// `liveContacts`, so outside that window the publication is pure cost.
  func retainLivePreview() {
    engineQueue.async { [weak self] in
      self?.livePreviewRetainCount += 1
    }
  }

  func releaseLivePreview() {
    engineQueue.async { [weak self] in
      guard let self else { return }
      self.livePreviewRetainCount = max(0, self.livePreviewRetainCount - 1)
      guard self.livePreviewRetainCount == 0 else { return }
      self.publish(liveContacts: [])
    }
  }

  private func publishLiveContacts(_ contacts: [TrackpadContact]) {
    guard livePreviewRetainCount > 0 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastLiveContactPublication >= (1 / 30) else { return }
    lastLiveContactPublication = now
    publish(liveContacts: contacts)
  }

  private func configureClickSuppression(enabled: Bool) {
    runOnMain { [weak self] in
      self?.clickSuppressor.apply(isEnabled: enabled)
    }
  }

  private func configureEdgeScrollSuppression(enabled: Bool) {
    runOnMain { [weak self] in
      self?.edgeScrollSuppressor.apply(isEnabled: enabled)
    }
  }

  private func publish(status: TrackpadRuntimeStatus) {
    runOnMain { [weak self] in self?.status = status }
  }

  private func publish(liveContacts: [TrackpadContact]) {
    runOnMain { [weak self] in self?.liveContacts = liveContacts }
  }

  private func publish(lastRecognition: String?) {
    runOnMain { [weak self] in self?.lastRecognition = lastRecognition }
  }

  private func publish(clickSuppressionStatus: TrackpadInputSuppressionStatus) {
    runOnMain { [weak self] in self?.clickSuppressionStatus = clickSuppressionStatus }
  }

  private func publish(edgeScrollSuppressionStatus: TrackpadInputSuppressionStatus) {
    runOnMain { [weak self] in
      self?.edgeScrollSuppressionStatus = edgeScrollSuppressionStatus
    }
  }

  private static func runtimeStatus(
    for sourceState: MultitouchTrackpadSourceState
  ) -> TrackpadRuntimeStatus {
    switch sourceState {
    case .disabled:
      return .disabled
    case .starting:
      return .starting
    case .running(let deviceCount):
      return .running(deviceCount: deviceCount)
    case .unsupported(let reason):
      return .unsupported(reason)
    case .failed(let reason):
      return .failed(reason)
    }
  }



  /// Modifier flags have to be read per frame because a rule can be held down mid-gesture.
  /// The frontmost application cannot change without an activation notification, so it is
  /// served from the cache that notification maintains.
  private func currentContext() -> TrackpadGestureContext {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    var modifiers = Set<TrackpadModifier>()
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
    return TrackpadGestureContext(
      bundleIdentifier: currentFrontmostBundleIdentifier(),
      modifiers: modifiers
    )
  }

  private func currentFrontmostBundleIdentifier() -> String? {
    frontmostLock.lock()
    let isPrimed = hasFrontmostBundleIdentifier
    let cached = frontmostBundleIdentifier
    frontmostLock.unlock()
    guard isPrimed else { return NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    return cached
  }

  private func runOnMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.async(execute: operation)
    }
  }
}
