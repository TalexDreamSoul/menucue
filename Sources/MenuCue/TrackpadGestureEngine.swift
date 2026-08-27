import Foundation

struct TrackpadGestureContext: Equatable {
  var bundleIdentifier: String?
  var modifiers: Set<TrackpadModifier>

  init(bundleIdentifier: String?, modifiers: Set<TrackpadModifier> = []) {
    self.bundleIdentifier = bundleIdentifier
    self.modifiers = modifiers
  }
}

/// Owns per-device session bookkeeping and hands each frame to every registered gesture
/// family in turn. It knows nothing about individual families beyond the registry order.
final class TrackpadGestureEngine {
  private struct Session {
    let deviceID: UInt64
    let isBuiltIn: Bool
    let beganAt: TimeInterval
    var fullContactBeganAt: TimeInterval
    let startModifiers: Set<TrackpadModifier>
    var lastTimestamp: TimeInterval
    var histories: [Int32: TrackpadContactHistory]
    var activeIDs: Set<Int32>
    var initialOrder: [Int32]
    var maxContactCount: Int
    var recognizerStates: [TrackpadGestureKind: TrackpadRecognizerSessionState]
    var emittedRuleIDs = Set<UUID>()
    var didEmitDiscrete = false
  }

  private var settings: TrackpadGestureSettings
  private var sessions: [UInt64: Session] = [:]
  private var sequence: UInt64 = 0
  private let recognizers: [TrackpadGestureRecognizer]
  private let recognizersByKind: [TrackpadGestureKind: TrackpadGestureRecognizer]

  init(settings: TrackpadGestureSettings = .default) {
    self.settings = settings.normalized
    let recognizers = TrackpadRecognizerRegistry.makeRecognizers()
    self.recognizers = recognizers
    self.recognizersByKind = Dictionary(uniqueKeysWithValues: recognizers.map { ($0.kind, $0) })
  }

  func apply(settings: TrackpadGestureSettings) {
    let normalized = settings.normalized
    guard normalized != self.settings else { return }
    self.settings = normalized
    reset()
  }

  func reset(deviceID: UInt64? = nil) {
    if let deviceID {
      sessions.removeValue(forKey: deviceID)
    } else {
      sessions.removeAll()
    }
    for recognizer in recognizers {
      recognizer.reset(deviceID: deviceID)
    }
  }

  func consume(frame: TrackpadFrame, context: TrackpadGestureContext) -> [TrackpadGestureMatch] {
    guard settings.isEnabled else {
      reset(deviceID: frame.deviceID)
      return []
    }

    if let existing = sessions[frame.deviceID], frame.timestamp < existing.lastTimestamp {
      reset(deviceID: frame.deviceID)
    }

    var frameContacts: [Int32: TrackpadContact] = [:]
    for contact in frame.contacts {
      guard frameContacts.updateValue(contact, forKey: contact.id) == nil else {
        reset(deviceID: frame.deviceID)
        return []
      }
    }
    let activeContacts = frameContacts.values.filter { $0.state.isTouching }
    let activeIDs = Set(activeContacts.map(\.id))

    if sessions[frame.deviceID] == nil {
      guard !activeContacts.isEmpty else { return [] }
      let histories = Dictionary(uniqueKeysWithValues: activeContacts.map {
        ($0.id, TrackpadContactHistory(contact: $0, timestamp: frame.timestamp))
      })
      let initialOrder = activeContacts.sorted {
        if $0.position.x == $1.position.x { return $0.id < $1.id }
        return $0.position.x < $1.position.x
      }.map(\.id)
      sessions[frame.deviceID] = Session(
        deviceID: frame.deviceID,
        isBuiltIn: frame.isBuiltIn,
        beganAt: frame.timestamp,
        fullContactBeganAt: frame.timestamp,
        startModifiers: context.modifiers,
        lastTimestamp: frame.timestamp,
        histories: histories,
        activeIDs: activeIDs,
        initialOrder: initialOrder,
        maxContactCount: activeContacts.count,
        recognizerStates: makeRecognizerStates()
      )
    }

    guard var session = sessions[frame.deviceID] else { return [] }
    let previousActive = session.activeIDs
    let beganIDs = activeIDs.subtracting(previousActive)
    var endedIDs = previousActive.subtracting(activeIDs)
    endedIDs.formUnion(frame.contacts.filter { $0.state.isEnding }.map(\.id))

    for contact in frame.contacts {
      if beganIDs.contains(contact.id), session.histories[contact.id]?.endedAt != nil {
        session.histories[contact.id] = TrackpadContactHistory(
          contact: contact,
          timestamp: frame.timestamp
        )
      } else if session.histories[contact.id] == nil {
        session.histories[contact.id] = TrackpadContactHistory(
          contact: contact,
          timestamp: frame.timestamp
        )
      } else {
        session.histories[contact.id]?.update(contact: contact, timestamp: frame.timestamp)
      }
      if contact.state.isEnding {
        session.histories[contact.id]?.endedAt = frame.timestamp
      }
    }
    for id in endedIDs where session.histories[id]?.endedAt == nil {
      session.histories[id]?.endedAt = frame.timestamp
    }

    session.lastTimestamp = frame.timestamp
    session.activeIDs = activeIDs
    if activeContacts.count > session.maxContactCount {
      session.maxContactCount = activeContacts.count
      session.fullContactBeganAt = frame.timestamp
      session.initialOrder = activeContacts.sorted {
        if $0.position.x == $1.position.x { return $0.id < $1.id }
        return $0.position.x < $1.position.x
      }.map(\.id)
    }

    // The rule table is walked once per frame; a session cannot change scope mid-gesture
    // because a settings change resets every session.
    let eligibleRules = TrackpadRuleMatcher.eligibleRules(
      settings.rules,
      context: TrackpadRuleContext(
        bundleIdentifier: context.bundleIdentifier,
        modifiers: session.startModifiers.isEmpty ? context.modifiers : session.startModifiers,
        isBuiltIn: session.isBuiltIn
      )
    )

    var matches: [TrackpadGestureMatch] = []
    var frameSnapshot = snapshot(of: session)
    for recognizer in recognizers {
      let input = makeInput(
        session: frameSnapshot,
        state: session.recognizerStates[recognizer.kind],
        contacts: frameContacts,
        activeContacts: activeContacts,
        beganIDs: beganIDs,
        endedIDs: endedIDs,
        eligibleRules: eligibleRules
      )
      var closedTheSession = false
      for gesture in recognizer.consume(input) {
        matches.append(makeMatch(gesture, timestamp: session.lastTimestamp))
        guard gesture.isDiscrete else { continue }
        session.emittedRuleIDs.insert(gesture.rule.id)
        session.didEmitDiscrete = true
        closedTheSession = true
      }
      // A discrete result closes the session for every family behind it in the registry,
      // so they have to see it on this frame, not the next one.
      if closedTheSession { frameSnapshot = snapshot(of: session) }
    }

    let shouldComplete = activeIDs.isEmpty && !session.histories.isEmpty
    if shouldComplete {
      let completionInput = makeInput(
        session: snapshot(of: session),
        state: nil,
        contacts: frameContacts,
        activeContacts: activeContacts,
        beganIDs: beganIDs,
        endedIDs: endedIDs,
        eligibleRules: eligibleRules
      )
      if let completion = completedMatch(input: completionInput) {
        matches.append(completion)
      }
      sessions.removeValue(forKey: frame.deviceID)
    } else {
      sessions[frame.deviceID] = session
    }
    return matches
  }

  /// Walks the eligible rules, not the families, so application specificity decides which
  /// rule wins a session several families could claim.
  private func completedMatch(input: TrackpadRecognizerInput) -> TrackpadGestureMatch? {
    let session = input.session
    guard !session.didEmitDiscrete else { return nil }
    for rule in input.eligibleRules where !session.emittedRuleIDs.contains(rule.id) {
      let trigger = rule.trigger.normalized
      guard trigger.fingerCount == session.maxContactCount,
        session.orderedHistories.count == trigger.fingerCount,
        session.duration >= 0,
        let recognizer = recognizersByKind[trigger.kind],
        recognizer.matchesCompletedSession(rule: rule, input: input)
      else { continue }
      return makeMatch(
        TrackpadRecognizedGesture(
          rule: rule,
          direction: recognizer.completionDirection(for: rule)
        ),
        timestamp: session.lastTimestamp
      )
    }
    return nil
  }

  private func makeRecognizerStates() -> [TrackpadGestureKind: TrackpadRecognizerSessionState] {
    Dictionary(uniqueKeysWithValues: recognizers.compactMap { recognizer in
      recognizer.makeSessionState().map { (recognizer.kind, $0) }
    })
  }

  private func makeInput(
    session: TrackpadSessionSnapshot,
    state: TrackpadRecognizerSessionState?,
    contacts: [Int32: TrackpadContact],
    activeContacts: [TrackpadContact],
    beganIDs: Set<Int32>,
    endedIDs: Set<Int32>,
    eligibleRules: [TrackpadGestureRule]
  ) -> TrackpadRecognizerInput {
    TrackpadRecognizerInput(
      contacts: contacts,
      activeContacts: activeContacts,
      beganIDs: beganIDs,
      endedIDs: endedIDs,
      session: session,
      edgeWidth: settings.edgeWidth,
      sensitivity: settings.sensitivity,
      eligibleRules: eligibleRules,
      state: state
    )
  }

  private func snapshot(of session: Session) -> TrackpadSessionSnapshot {
    TrackpadSessionSnapshot(
      deviceID: session.deviceID,
      isBuiltIn: session.isBuiltIn,
      beganAt: session.beganAt,
      fullContactBeganAt: session.fullContactBeganAt,
      lastTimestamp: session.lastTimestamp,
      activeIDs: session.activeIDs,
      initialOrder: session.initialOrder,
      maxContactCount: session.maxContactCount,
      histories: session.histories,
      orderedHistories: Self.orderedHistories(session),
      emittedRuleIDs: session.emittedRuleIDs,
      didEmitDiscrete: session.didEmitDiscrete
    )
  }

  private static func orderedHistories(_ session: Session) -> [TrackpadContactHistory] {
    let ordered = session.initialOrder.compactMap { session.histories[$0] }
    if ordered.count == session.histories.count { return ordered }
    let remaining = session.histories.values.filter { history in
      !session.initialOrder.contains(history.id)
    }.sorted { $0.start.x < $1.start.x }
    return ordered + remaining
  }

  private func makeMatch(
    _ gesture: TrackpadRecognizedGesture,
    timestamp: TimeInterval
  ) -> TrackpadGestureMatch {
    sequence &+= 1
    return TrackpadGestureMatch(
      id: sequence,
      rule: gesture.rule,
      direction: gesture.direction,
      continuousDelta: gesture.continuousDelta,
      timestamp: timestamp
    )
  }
}
