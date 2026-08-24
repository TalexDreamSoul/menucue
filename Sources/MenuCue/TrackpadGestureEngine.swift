import Foundation

struct TrackpadGestureContext: Equatable {
  var bundleIdentifier: String?
  var modifiers: Set<TrackpadModifier>

  init(bundleIdentifier: String?, modifiers: Set<TrackpadModifier> = []) {
    self.bundleIdentifier = bundleIdentifier
    self.modifiers = modifiers
  }
}

final class TrackpadGestureEngine {
  private struct ContactHistory {
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

  private struct PendingTipTap {
    let selectedFingerIndex: Int
    let initialPosition: TrackpadPoint
    let initialTravel: Double
    let gapBeganAt: TimeInterval
    let heldDuration: TimeInterval
    let anchorIDs: Set<Int32>
    var recontactID: Int32?
    var recontactBeganAt: TimeInterval?
  }

  private struct LastTap {
    let timestamp: TimeInterval
    let position: TrackpadPoint
  }
  private struct DoubleTapKey: Hashable {
    let deviceID: UInt64
    let ruleID: UUID
  }

  private struct Session {
    let deviceID: UInt64
    let isBuiltIn: Bool
    let beganAt: TimeInterval
    var fullContactBeganAt: TimeInterval
    let startModifiers: Set<TrackpadModifier>
    var lastTimestamp: TimeInterval
    var histories: [Int32: ContactHistory]
    var activeIDs: Set<Int32>
    var initialOrder: [Int32]
    var maxContactCount: Int
    var pendingTipTap: PendingTipTap?
    var continuousRemainders: [UUID: Double] = [:]
    var continuousLastFire: [UUID: TimeInterval] = [:]
    var continuousLastPositions: [UUID: TrackpadPoint] = [:]
    var continuousCancelledRuleIDs = Set<UUID>()
    var emittedRuleIDs = Set<UUID>()
    var didEmitDiscrete = false
  }

  private var settings: TrackpadGestureSettings
  private var sessions: [UInt64: Session] = [:]
  private var lastTaps: [DoubleTapKey: LastTap] = [:]
  private var sequence: UInt64 = 0

  init(settings: TrackpadGestureSettings = .default) {
    self.settings = settings.normalized
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
      lastTaps = lastTaps.filter { $0.key.deviceID != deviceID }
    } else {
      sessions.removeAll()
      lastTaps.removeAll()
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
        ($0.id, ContactHistory(contact: $0, timestamp: frame.timestamp))
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
        pendingTipTap: nil
      )
    }

    guard var session = sessions[frame.deviceID] else { return [] }
    let previousActive = session.activeIDs
    let beganIDs = activeIDs.subtracting(previousActive)
    var endedIDs = previousActive.subtracting(activeIDs)
    endedIDs.formUnion(frame.contacts.filter { $0.state.isEnding }.map(\.id))

    for contact in frame.contacts {
      if beganIDs.contains(contact.id), session.histories[contact.id]?.endedAt != nil {
        session.histories[contact.id] = ContactHistory(contact: contact, timestamp: frame.timestamp)
      } else if session.histories[contact.id] == nil {
        session.histories[contact.id] = ContactHistory(contact: contact, timestamp: frame.timestamp)
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

    var matches: [TrackpadGestureMatch] = []
    matches.append(contentsOf: consumeTipTap(
      session: &session,
      frameContacts: frameContacts,
      beganIDs: beganIDs,
      endedIDs: endedIDs,
      context: context
    ))
    matches.append(contentsOf: consumeContinuousEdges(
      session: &session,
      activeContacts: activeContacts,
      context: context
    ))

    let shouldComplete = activeIDs.isEmpty && !session.histories.isEmpty
    if shouldComplete {
      if let completion = consumeCompletedSession(session, context: context) {
        matches.append(completion)
      }
      sessions.removeValue(forKey: frame.deviceID)
    } else {
      sessions[frame.deviceID] = session
    }
    return matches
  }

  private func consumeTipTap(
    session: inout Session,
    frameContacts: [Int32: TrackpadContact],
    beganIDs: Set<Int32>,
    endedIDs: Set<Int32>,
    context: TrackpadGestureContext
  ) -> [TrackpadGestureMatch] {
    guard !session.didEmitDiscrete,
      session.maxContactCount >= 2,
      session.maxContactCount <= 4
    else { return [] }

    if session.pendingTipTap == nil,
      endedIDs.count == 1,
      let endedID = endedIDs.first,
      let selectedIndex = session.initialOrder.firstIndex(of: endedID),
      let history = session.histories[endedID],
      session.activeIDs.count == session.maxContactCount - 1
    {
      session.pendingTipTap = PendingTipTap(
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

    if var pending = session.pendingTipTap,
      pending.recontactID == nil,
      beganIDs.count == 1,
      let newID = beganIDs.first,
      pending.anchorIDs.isSubset(of: session.activeIDs),
      let contact = frameContacts[newID],
      contact.position.distance(to: pending.initialPosition) <= 0.2
    {
      pending.recontactID = newID
      pending.recontactBeganAt = session.lastTimestamp
      session.pendingTipTap = pending
      return []
    }

    guard let pending = session.pendingTipTap,
      let recontactID = pending.recontactID,
      endedIDs.contains(recontactID),
      let recontactStart = pending.recontactBeganAt,
      let history = session.histories[recontactID],
      pending.anchorIDs.isSubset(of: session.activeIDs),
      session.activeIDs.count == pending.anchorIDs.count
    else { return [] }

    defer { session.pendingTipTap = nil }
    let tapDuration = session.lastTimestamp - recontactStart
    let eligible = eligibleRules(context: context, session: session).filter {
      $0.trigger.kind == .tipTap
        && $0.trigger.fingerCount == session.maxContactCount
        && $0.trigger.selectedFingerIndex == pending.selectedFingerIndex
        && !session.emittedRuleIDs.contains($0.id)
    }
    guard let rule = eligible.first(where: { rule in
      let trigger = rule.trigger.normalized
      let anchorsStayedStill = pending.anchorIDs.allSatisfy { id in
        guard let anchor = session.histories[id] else { return false }
        return anchor.maxTravel <= trigger.movementTolerance
      }
      guard pending.heldDuration >= trigger.holdDuration,
        session.lastTimestamp - pending.gapBeganAt <= trigger.maximumDuration,
        tapDuration <= min(0.35, trigger.maximumDuration),
        pending.initialTravel <= trigger.movementTolerance,
        history.maxTravel <= trigger.movementTolerance,
        anchorsStayedStill
      else { return false }
      return tipTapSpacingMatches(trigger.tapSpacing, session: session, selectedIndex: pending.selectedFingerIndex)
    }) else { return [] }

    session.emittedRuleIDs.insert(rule.id)
    session.didEmitDiscrete = true
    return [makeMatch(rule: rule, timestamp: session.lastTimestamp)]
  }

  private func tipTapSpacingMatches(
    _ spacing: TrackpadTapSpacing,
    session: Session,
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
    case .near: return nearest <= 0.23
    case .normal: return true
    case .far: return nearest >= 0.4
    }
  }

  private func cancelContinuousRules(
    _ rules: [TrackpadGestureRule],
    session: inout Session
  ) {
    for rule in rules {
      session.continuousCancelledRuleIDs.insert(rule.id)
      session.continuousRemainders.removeValue(forKey: rule.id)
      session.continuousLastPositions.removeValue(forKey: rule.id)
    }
  }

  private func consumeContinuousEdges(
    session: inout Session,
    activeContacts: [TrackpadContact],
    context: TrackpadGestureContext
  ) -> [TrackpadGestureMatch] {
    let edgeRules = eligibleRules(context: context, session: session).filter {
      $0.trigger.kind == .edgeContinuous && $0.trigger.fingerCount == 2
    }
    guard !edgeRules.isEmpty else { return [] }

    let requiredContactCount = 2
    if session.maxContactCount < requiredContactCount {
      return []
    }
    guard session.maxContactCount == requiredContactCount,
      session.histories.count == requiredContactCount,
      activeContacts.count == requiredContactCount
    else {
      cancelContinuousRules(edgeRules, session: &session)
      return []
    }

    let activeHistories: [(contact: TrackpadContact, history: ContactHistory)] =
      activeContacts.compactMap { contact in
        guard let history = session.histories[contact.id] else { return nil }
        return (contact, history)
      }
    guard activeHistories.count == requiredContactCount else {
      cancelContinuousRules(edgeRules, session: &session)
      return []
    }
    let currentCentroid = centroid(activeHistories.map { $0.contact.position })

    var matches: [TrackpadGestureMatch] = []
    for rule in edgeRules {
      guard !session.continuousCancelledRuleIDs.contains(rule.id) else { continue }
      let trigger = rule.trigger.normalized
      guard activeHistories.allSatisfy({ pair in
        edgeContainsStart(trigger.edge, point: pair.history.start, width: settings.edgeWidth)
          && edgeContainsCurrent(
            trigger.edge,
            point: pair.contact.position,
            width: settings.edgeWidth
          )
      }) else {
        session.continuousCancelledRuleIDs.insert(rule.id)
        session.continuousRemainders.removeValue(forKey: rule.id)
        session.continuousLastPositions.removeValue(forKey: rule.id)
        continue
      }

      guard let previousPosition = session.continuousLastPositions[rule.id] else {
        session.continuousLastPositions[rule.id] = currentCentroid
        continue
      }
      session.continuousLastPositions[rule.id] = currentCentroid
      let rawDelta: Double
      switch trigger.edge {
      case .left, .right: rawDelta = currentCentroid.y - previousPosition.y
      case .top, .bottom: rawDelta = currentCentroid.x - previousPosition.x
      }
      let delta = trigger.isInverted ? -rawDelta : rawDelta
      var remainder = session.continuousRemainders[rule.id, default: 0] + delta
      let threshold = max(0.004, trigger.minimumDistance / settings.sensitivity)
      let availableSteps = Int(abs(remainder) / threshold)
      guard availableSteps > 0 else {
        session.continuousRemainders[rule.id] = remainder
        continue
      }
      let lastFire = session.continuousLastFire[rule.id] ?? -.greatestFiniteMagnitude
      guard session.lastTimestamp - lastFire >= 0.055 else {
        session.continuousRemainders[rule.id] = remainder
        continue
      }
      let signedSteps = (remainder > 0 ? 1 : -1) * min(3, availableSteps)
      remainder -= Double(signedSteps) * threshold
      session.continuousRemainders[rule.id] = remainder
      session.continuousLastFire[rule.id] = session.lastTimestamp
      matches.append(makeMatch(
        rule: rule,
        direction: direction(
          forSignedDelta: Double(signedSteps),
          vertical: trigger.edge == .left || trigger.edge == .right
        ),
        continuousDelta: Double(signedSteps),
        timestamp: session.lastTimestamp
      ))
      break
    }
    return matches
  }

  private func consumeCompletedSession(
    _ session: Session,
    context: TrackpadGestureContext
  ) -> TrackpadGestureMatch? {
    guard !session.didEmitDiscrete else { return nil }
    let rules = eligibleRules(context: context, session: session)
    for rule in rules where !session.emittedRuleIDs.contains(rule.id) {
      if completionMatches(rule: rule, session: session) {
        return makeMatch(
          rule: rule,
          direction: completionDirection(rule: rule, session: session),
          timestamp: session.lastTimestamp
        )
      }
    }
    return nil
  }

  private func completionMatches(rule: TrackpadGestureRule, session: Session) -> Bool {
    let trigger = rule.trigger.normalized
    guard trigger.fingerCount == session.maxContactCount else { return false }
    let histories = orderedHistories(session)
    guard histories.count == trigger.fingerCount else { return false }
    let duration = session.lastTimestamp - session.beganAt
    guard duration >= 0 else { return false }
    let centroidStart = centroid(histories.map(\.start))
    let centroidEnd = centroid(histories.map(\.last))
    let displacement = centroidStart.distance(to: centroidEnd)

    switch trigger.kind {
    case .contact:
      guard duration <= trigger.maximumDuration,
        histories.allSatisfy({ $0.maxTravel <= trigger.movementTolerance }),
        regionMatches(trigger.region, point: centroidStart)
      else { return false }
      switch trigger.contactGesture {
      case .tap: return true
      case .doubleTap:
        let key = DoubleTapKey(deviceID: session.deviceID, ruleID: rule.id)
        if let previous = lastTaps[key] {
          let interval = session.lastTimestamp - previous.timestamp
          if interval >= 0,
            interval <= min(0.5, trigger.maximumDuration),
            previous.position.distance(to: centroidStart) <= trigger.movementTolerance * 2
          {
            lastTaps.removeValue(forKey: key)
            return true
          }
        }
        lastTaps[key] = LastTap(timestamp: session.lastTimestamp, position: centroidStart)
        return false
      case .click:
        return histories.contains { $0.maxDensity >= 1 || $0.maxSize >= 2 }
      case .forceClick:
        return histories.contains { $0.maxDensity >= 2.2 || $0.maxSize >= 4 }
      }

    case .swipe:
      guard duration <= trigger.maximumDuration else { return false }
      guard displacement >= trigger.minimumDistance,
        direction(from: centroidStart, to: centroidEnd) == trigger.direction
      else { return false }
      return velocity(distance: displacement, duration: duration) >= trigger.minimumVelocity

    case .edgeEntrySwipe:
      guard duration <= trigger.maximumDuration else { return false }
      guard displacement >= trigger.minimumDistance,
        direction(from: centroidStart, to: centroidEnd) == trigger.direction,
        edgeContainsStart(trigger.edge, point: centroidStart, width: settings.edgeWidth * 1.5)
      else { return false }
      return velocity(distance: displacement, duration: duration) >= trigger.minimumVelocity

    case .pinch:
      guard duration <= trigger.maximumDuration, histories.count >= 2 else { return false }
      let startSpread = spread(histories.map(\.start))
      let endSpread = spread(histories.map(\.last))
      let change = endSpread - startSpread
      guard abs(change) >= trigger.minimumDistance else { return false }
      return trigger.pinchDirection == .outward ? change > 0 : change < 0

    case .fingerSwipe:
      guard duration <= trigger.maximumDuration else { return false }
      guard histories.indices.contains(trigger.selectedFingerIndex) else { return false }
      let selected = histories[trigger.selectedFingerIndex]
      let selectedDistance = selected.start.distance(to: selected.last)
      guard selectedDistance >= trigger.minimumDistance,
        direction(from: selected.start, to: selected.last) == trigger.direction
      else { return false }
      return histories.enumerated().allSatisfy { index, history in
        index == trigger.selectedFingerIndex || history.maxTravel <= trigger.movementTolerance
      }

    case .drawing:
      guard duration <= trigger.maximumDuration else { return false }
      guard let path = drawingPath(for: trigger, histories: histories),
        path.count >= 8,
        trigger.drawingTemplate.count >= 8
      else { return false }
      return unistrokeScore(path, template: trigger.drawingTemplate) >= trigger.minimumDrawingScore

    case .tipTap, .edgeContinuous:
      return false
    }
  }

  private func drawingPath(
    for trigger: TrackpadGestureTrigger,
    histories: [ContactHistory]
  ) -> [TrackpadPoint]? {
    switch trigger.drawingActivation {
    case .modifier:
      return histories.max(by: { $0.points.count < $1.points.count })?.points
    case .bottomThumb:
      guard histories.contains(where: { $0.start.y <= settings.edgeWidth * 1.5 }) else { return nil }
      return histories.filter { $0.start.y > settings.edgeWidth * 1.5 }
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

  private func eligibleRules(
    context: TrackpadGestureContext,
    session: Session
  ) -> [TrackpadGestureRule] {
    settings.rules.enumerated().filter { _, rule in
      guard rule.isEnabled,
        rule.applicationScope.matches(bundleIdentifier: context.bundleIdentifier),
        rule.requiredModifiers == (session.startModifiers.isEmpty ? context.modifiers : session.startModifiers)
      else { return false }
      switch rule.deviceScope {
      case .allSupported: return true
      case .builtInOnly: return session.isBuiltIn
      case .externalOnly: return !session.isBuiltIn
      }
    }.sorted { lhs, rhs in
      let leftSpecificity = lhs.element.applicationScope.specificity
      let rightSpecificity = rhs.element.applicationScope.specificity
      if leftSpecificity == rightSpecificity { return lhs.offset < rhs.offset }
      return leftSpecificity > rightSpecificity
    }.map(\.element)
  }

  private func orderedHistories(_ session: Session) -> [ContactHistory] {
    let ordered = session.initialOrder.compactMap { session.histories[$0] }
    if ordered.count == session.histories.count { return ordered }
    let remaining = session.histories.values.filter { history in
      !session.initialOrder.contains(history.id)
    }.sorted { $0.start.x < $1.start.x }
    return ordered + remaining
  }

  private func completionDirection(
    rule: TrackpadGestureRule,
    session: Session
  ) -> TrackpadDirection? {
    switch rule.trigger.kind {
    case .swipe, .edgeEntrySwipe, .fingerSwipe: return rule.trigger.direction
    case .pinch: return rule.trigger.pinchDirection == .outward ? .right : .left
    default: return nil
    }
  }

  private func makeMatch(
    rule: TrackpadGestureRule,
    direction: TrackpadDirection? = nil,
    continuousDelta: Double = 0,
    timestamp: TimeInterval
  ) -> TrackpadGestureMatch {
    sequence &+= 1
    return TrackpadGestureMatch(
      id: sequence,
      rule: rule,
      direction: direction,
      continuousDelta: continuousDelta,
      timestamp: timestamp
    )
  }

  private func centroid(_ points: [TrackpadPoint]) -> TrackpadPoint {
    guard !points.isEmpty else { return TrackpadPoint(x: 0, y: 0) }
    let sum = points.reduce((x: 0.0, y: 0.0)) { partial, point in
      (partial.x + point.x, partial.y + point.y)
    }
    return TrackpadPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
  }

  private func spread(_ points: [TrackpadPoint]) -> Double {
    guard points.count >= 2 else { return 0 }
    let center = centroid(points)
    return points.map { center.distance(to: $0) }.reduce(0, +) / Double(points.count)
  }

  private func velocity(distance: Double, duration: TimeInterval) -> Double {
    distance / max(0.001, duration)
  }

  private func direction(from start: TrackpadPoint, to end: TrackpadPoint) -> TrackpadDirection {
    let dx = end.x - start.x
    let dy = end.y - start.y
    if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
    return dy >= 0 ? .up : .down
  }

  private func direction(forSignedDelta delta: Double, vertical: Bool) -> TrackpadDirection {
    if vertical { return delta >= 0 ? .up : .down }
    return delta >= 0 ? .right : .left
  }

  private func edgeContainsStart(
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

  private func edgeContainsCurrent(
    _ edge: TrackpadEdge,
    point: TrackpadPoint,
    width: Double
  ) -> Bool {
    edgeContainsStart(edge, point: point, width: min(0.35, width + 0.06))
  }

  private func regionMatches(_ region: TrackpadGestureRegion, point: TrackpadPoint) -> Bool {
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

  private func unistrokeScore(_ path: [TrackpadPoint], template: [TrackpadPoint]) -> Double {
    let normalizedPath = normalizeStroke(path)
    let normalizedTemplate = normalizeStroke(template)
    guard normalizedPath.count == normalizedTemplate.count, !normalizedPath.isEmpty else { return 0 }
    let distance = zip(normalizedPath, normalizedTemplate)
      .map { pair in pair.0.distance(to: pair.1) }
      .reduce(0, +) / Double(normalizedPath.count)
    return max(0, 1 - distance / 0.5)
  }

  private func normalizeStroke(_ points: [TrackpadPoint]) -> [TrackpadPoint] {
    let sampled = resample(points, count: 64)
    guard sampled.count > 1 else { return sampled }
    let center = centroid(sampled)
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
    let scaledCenter = centroid(scaled)
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
