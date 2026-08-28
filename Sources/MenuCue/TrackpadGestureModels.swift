import Foundation

enum TrackpadModifier: String, CaseIterable, Codable, Hashable, Identifiable {
  case function
  case shift
  case control
  case option
  case command

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .function: return "fn"
    case .shift: return "⇧"
    case .control: return "⌃"
    case .option: return "⌥"
    case .command: return "⌘"
    }
  }
}

struct TrackpadApplicationIdentity: Codable, Equatable, Hashable, Identifiable {
  var bundleIdentifier: String
  var name: String
  var path: String?

  var id: String { bundleIdentifier }

  init(bundleIdentifier: String, name: String, path: String? = nil) {
    self.bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.path = path
  }
}

enum TrackpadApplicationScopeMode: String, CaseIterable, Codable, Identifiable {
  case allApplications
  case includedApplications
  case excludedApplications

  var id: String { rawValue }
}

struct TrackpadApplicationScope: Codable, Equatable {
  var mode: TrackpadApplicationScopeMode
  var applications: [TrackpadApplicationIdentity]

  static let all = TrackpadApplicationScope(mode: .allApplications, applications: [])

  var specificity: Int {
    switch mode {
    case .allApplications: return 0
    case .includedApplications, .excludedApplications: return 1
    }
  }

  func matches(bundleIdentifier: String?) -> Bool {
    let identifier = bundleIdentifier ?? ""
    let contains = applications.contains { $0.bundleIdentifier == identifier }
    switch mode {
    case .allApplications: return true
    case .includedApplications: return contains
    case .excludedApplications: return !contains
    }
  }

  var normalized: TrackpadApplicationScope {
    var seen = Set<String>()
    let normalizedApps = applications.compactMap { application -> TrackpadApplicationIdentity? in
      let identifier = application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !identifier.isEmpty, seen.insert(identifier).inserted else { return nil }
      let name = application.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return TrackpadApplicationIdentity(
        bundleIdentifier: identifier,
        name: name.isEmpty ? identifier : name,
        path: application.path
      )
    }
    if mode == .allApplications {
      return .all
    }
    return TrackpadApplicationScope(mode: mode, applications: normalizedApps)
  }
}

enum TrackpadDeviceScope: String, CaseIterable, Codable, Identifiable {
  case allSupported
  case builtInOnly
  case externalOnly

  var id: String { rawValue }
}

struct TrackpadPoint: Codable, Equatable, Hashable {
  var x: Double
  var y: Double

  var clamped: TrackpadPoint {
    TrackpadPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
  }

  func distance(to other: TrackpadPoint) -> Double {
    hypot(other.x - x, other.y - y)
  }
}

enum TrackpadGestureKind: String, CaseIterable, Codable, Identifiable {
  case contact
  case swipe
  case edgeEntrySwipe
  case pinch
  case tipTap
  case fingerSwipe
  case drawing
  case edgeContinuous

  var id: String { rawValue }
}

enum TrackpadContactGesture: String, CaseIterable, Codable, Identifiable {
  case tap
  case doubleTap
  case click
  case forceClick

  var id: String { rawValue }
}

enum TrackpadDirection: String, CaseIterable, Codable, Identifiable {
  case up
  case down
  case left
  case right

  var id: String { rawValue }
}

enum TrackpadEdge: String, CaseIterable, Codable, Identifiable {
  case left
  case right
  case top
  case bottom

  var id: String { rawValue }
}

enum TrackpadGestureRegion: String, CaseIterable, Codable, Identifiable {
  case anywhere
  case center
  case left
  case right
  case topLeft
  case topMiddle
  case topRight
  case leftMiddle
  case rightMiddle
  case bottomLeft
  case bottomMiddle
  case bottomRight

  var id: String { rawValue }
}

enum TrackpadPinchDirection: String, CaseIterable, Codable, Identifiable {
  case inward
  case outward

  var id: String { rawValue }
}

enum TrackpadTapSpacing: String, CaseIterable, Codable, Identifiable {
  case near
  case normal
  case far

  var id: String { rawValue }
}

enum TrackpadDrawingActivation: String, CaseIterable, Codable, Identifiable {
  case modifier
  case bottomThumb
  case holdTap

  var id: String { rawValue }
}

struct TrackpadGestureTrigger: Codable, Equatable {
  var kind: TrackpadGestureKind
  var fingerCount: Int
  var contactGesture: TrackpadContactGesture
  var direction: TrackpadDirection
  var edge: TrackpadEdge
  var region: TrackpadGestureRegion
  /// Zero-based left-to-right contact index at the moment the gesture arms.
  var selectedFingerIndex: Int
  var tapSpacing: TrackpadTapSpacing
  var pinchDirection: TrackpadPinchDirection
  var drawingActivation: TrackpadDrawingActivation
  var drawingTemplate: [TrackpadPoint]
  var isInverted: Bool
  var holdDuration: TimeInterval
  var maximumDuration: TimeInterval
  var movementTolerance: Double
  var minimumDistance: Double
  var minimumVelocity: Double
  var minimumDrawingScore: Double

  init(
    kind: TrackpadGestureKind,
    fingerCount: Int = 1,
    contactGesture: TrackpadContactGesture = .tap,
    direction: TrackpadDirection = .up,
    edge: TrackpadEdge = .left,
    region: TrackpadGestureRegion = .anywhere,
    selectedFingerIndex: Int = 0,
    tapSpacing: TrackpadTapSpacing = .normal,
    pinchDirection: TrackpadPinchDirection = .inward,
    drawingActivation: TrackpadDrawingActivation = .modifier,
    drawingTemplate: [TrackpadPoint] = [],
    isInverted: Bool = false,
    holdDuration: TimeInterval = 0.22,
    maximumDuration: TimeInterval = 0.6,
    movementTolerance: Double = 0.035,
    minimumDistance: Double = 0.08,
    minimumVelocity: Double = 0,
    minimumDrawingScore: Double = 0.72
  ) {
    self.kind = kind
    self.fingerCount = fingerCount
    self.contactGesture = contactGesture
    self.direction = direction
    self.edge = edge
    self.region = region
    self.selectedFingerIndex = selectedFingerIndex
    self.tapSpacing = tapSpacing
    self.pinchDirection = pinchDirection
    self.drawingActivation = drawingActivation
    self.drawingTemplate = drawingTemplate
    self.isInverted = isInverted
    self.holdDuration = holdDuration
    self.maximumDuration = maximumDuration
    self.movementTolerance = movementTolerance
    self.minimumDistance = minimumDistance
    self.minimumVelocity = minimumVelocity
    self.minimumDrawingScore = minimumDrawingScore
  }

  var normalized: TrackpadGestureTrigger {
    var result = self
    result.fingerCount = min(5, max(1, fingerCount))
    if result.kind == .edgeContinuous {
      result.fingerCount = 2
    }
    result.selectedFingerIndex = min(result.fingerCount - 1, max(0, selectedFingerIndex))
    result.holdDuration = min(1.5, max(0.08, holdDuration))
    result.maximumDuration = min(3, max(0.12, maximumDuration))
    result.movementTolerance = min(0.25, max(0.005, movementTolerance))
    result.minimumDistance = min(0.8, max(0.005, minimumDistance))
    result.minimumVelocity = min(10, max(0, minimumVelocity))
    result.minimumDrawingScore = min(0.98, max(0.3, minimumDrawingScore))
    result.drawingTemplate = Array(drawingTemplate.prefix(256)).map(\.clamped)
    return result
  }
}

enum TrackpadGestureActionKind: String, CaseIterable, Codable, Identifiable {
  case systemControl
  case quickAction
  case keyboardShortcut
  case mouse
  case scroll
  case open
  case appleScript
  case window
  case none

  var id: String { rawValue }
}

enum TrackpadSystemControl: String, CaseIterable, Codable, Identifiable {
  case volumeUp
  case volumeDown
  case toggleMute
  case brightnessUp
  case brightnessDown
  case continuousVolume
  case continuousBrightness

  var id: String { rawValue }
}

enum TrackpadMouseAction: String, CaseIterable, Codable, Identifiable {
  case leftClick
  case rightClick
  case middleClick

  var id: String { rawValue }
}

enum TrackpadOpenTargetKind: String, CaseIterable, Codable, Identifiable {
  case application
  case url
  case file
  case folder

  var id: String { rawValue }
}

enum TrackpadWindowAction: String, CaseIterable, Codable, Identifiable {
  case leftHalf
  case rightHalf
  case topHalf
  case bottomHalf
  case topLeftQuarter
  case topRightQuarter
  case bottomLeftQuarter
  case bottomRightQuarter
  case maximize
  case center
  case restore
  case nextDisplay

  var id: String { rawValue }
}

struct TrackpadKeyboardShortcut: Codable, Equatable {
  var keyCode: UInt16
  var characters: String
  var modifiers: Set<TrackpadModifier>

  init(keyCode: UInt16 = 0, characters: String = "", modifiers: Set<TrackpadModifier> = []) {
    self.keyCode = keyCode
    self.characters = characters
    self.modifiers = modifiers
  }
}

struct TrackpadGestureAction: Codable, Equatable {
  var kind: TrackpadGestureActionKind
  var systemControl: TrackpadSystemControl
  /// `QuickActionReference.storageValue`, preserving the existing action identity contract.
  var quickActionStorageValue: String
  var keyboardShortcut: TrackpadKeyboardShortcut
  var mouseAction: TrackpadMouseAction
  var scrollDirection: TrackpadDirection
  var openTargetKind: TrackpadOpenTargetKind
  var target: String
  var appleScript: String
  var windowAction: TrackpadWindowAction

  init(
    kind: TrackpadGestureActionKind,
    systemControl: TrackpadSystemControl = .volumeUp,
    quickActionStorageValue: String = "",
    keyboardShortcut: TrackpadKeyboardShortcut = TrackpadKeyboardShortcut(),
    mouseAction: TrackpadMouseAction = .leftClick,
    scrollDirection: TrackpadDirection = .down,
    openTargetKind: TrackpadOpenTargetKind = .application,
    target: String = "",
    appleScript: String = "",
    windowAction: TrackpadWindowAction = .center
  ) {
    self.kind = kind
    self.systemControl = systemControl
    self.quickActionStorageValue = quickActionStorageValue
    self.keyboardShortcut = keyboardShortcut
    self.mouseAction = mouseAction
    self.scrollDirection = scrollDirection
    self.openTargetKind = openTargetKind
    self.target = target
    self.appleScript = appleScript
    self.windowAction = windowAction
  }

  static func system(_ control: TrackpadSystemControl) -> TrackpadGestureAction {
    TrackpadGestureAction(kind: .systemControl, systemControl: control)
  }
}

struct TrackpadGestureRule: Codable, Equatable, Identifiable {
  var id: UUID
  var name: String
  var note: String
  var isEnabled: Bool
  var requiredModifiers: Set<TrackpadModifier>
  var applicationScope: TrackpadApplicationScope
  var deviceScope: TrackpadDeviceScope
  var activatesWindowUnderPointer: Bool
  var trigger: TrackpadGestureTrigger
  var action: TrackpadGestureAction

  init(
    id: UUID = UUID(),
    name: String,
    note: String = "",
    isEnabled: Bool = true,
    requiredModifiers: Set<TrackpadModifier> = [],
    applicationScope: TrackpadApplicationScope = .all,
    deviceScope: TrackpadDeviceScope = .allSupported,
    activatesWindowUnderPointer: Bool = false,
    trigger: TrackpadGestureTrigger,
    action: TrackpadGestureAction
  ) {
    self.id = id
    self.name = name
    self.note = note
    self.isEnabled = isEnabled
    self.requiredModifiers = requiredModifiers
    self.applicationScope = applicationScope
    self.deviceScope = deviceScope
    self.activatesWindowUnderPointer = activatesWindowUnderPointer
    self.trigger = trigger.normalized
    self.action = action
  }

  /// Preset rules ship with English names in storage, so only those are translated; a
  /// name the user typed is shown exactly as typed.
  var settingsDisplayName: String {
    let presetNames = Set(TrackpadGestureSettings.presetRules.map(\.name))
    return presetNames.contains(name) ? L10n.string(name) : name
  }

  var normalized: TrackpadGestureRule {
    var result = self
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.name.isEmpty { result.name = "Trackpad Gesture" }
    result.note = note.trimmingCharacters(in: .newlines)
    result.applicationScope = applicationScope.normalized
    result.trigger = trigger.normalized
    return result
  }
}

struct TrackpadGestureSettings: Codable, Equatable {
  var isEnabled: Bool
  var hapticFeedbackEnabled: Bool
  var feedbackHUDEnabled: Bool
  var suppressesClickAfterMultiFingerTap: Bool
  var edgeWidth: Double
  var sensitivity: Double
  var rules: [TrackpadGestureRule]

  init(
    isEnabled: Bool = false,
    hapticFeedbackEnabled: Bool = true,
    feedbackHUDEnabled: Bool = true,
    suppressesClickAfterMultiFingerTap: Bool = false,
    edgeWidth: Double = 0.08,
    sensitivity: Double = 1,
    rules: [TrackpadGestureRule] = TrackpadGestureSettings.presetRules
  ) {
    self.isEnabled = isEnabled
    self.hapticFeedbackEnabled = hapticFeedbackEnabled
    self.feedbackHUDEnabled = feedbackHUDEnabled
    self.suppressesClickAfterMultiFingerTap = suppressesClickAfterMultiFingerTap
    self.edgeWidth = edgeWidth
    self.sensitivity = sensitivity
    self.rules = rules
    self = normalized
  }

  static let `default` = TrackpadGestureSettings()

  static let presetRules: [TrackpadGestureRule] = [
    TrackpadGestureRule(
      name: "Left finger tap · Volume Up",
      trigger: TrackpadGestureTrigger(
        kind: .tipTap,
        fingerCount: 2,
        selectedFingerIndex: 0,
        tapSpacing: .normal,
        holdDuration: 0.18,
        maximumDuration: 0.65,
        movementTolerance: 0.035
      ),
      action: .system(.volumeUp)
    ),
    TrackpadGestureRule(
      name: "Right finger tap · Volume Down",
      trigger: TrackpadGestureTrigger(
        kind: .tipTap,
        fingerCount: 2,
        selectedFingerIndex: 1,
        tapSpacing: .normal,
        holdDuration: 0.18,
        maximumDuration: 0.65,
        movementTolerance: 0.035
      ),
      action: .system(.volumeDown)
    ),
    TrackpadGestureRule(
      name: "Left edge · Volume",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .left,
        minimumDistance: 0.018
      ),
      action: .system(.continuousVolume)
    ),
    TrackpadGestureRule(
      name: "Right edge · Brightness",
      trigger: TrackpadGestureTrigger(
        kind: .edgeContinuous,
        fingerCount: 2,
        edge: .right,
        minimumDistance: 0.018
      ),
      action: .system(.continuousBrightness)
    ),
  ]

  var normalized: TrackpadGestureSettings {
    var result = self
    result.edgeWidth = min(0.2, max(0.03, edgeWidth))
    result.sensitivity = min(4, max(0.25, sensitivity))
    var seen = Set<UUID>()
    result.rules = Array(rules.prefix(256)).map { rule in
      var normalizedRule = rule.normalized
      if !seen.insert(normalizedRule.id).inserted {
        normalizedRule.id = UUID()
        seen.insert(normalizedRule.id)
      }
      return normalizedRule
    }
    return result
  }
}

struct TrackpadRuleSetEnvelope: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var exportedAt: Date
  var settings: TrackpadGestureSettings

  init(settings: TrackpadGestureSettings, exportedAt: Date = Date()) {
    self.schemaVersion = Self.currentSchemaVersion
    self.exportedAt = exportedAt
    self.settings = settings.normalized
  }

  func importedSettings() throws -> TrackpadGestureSettings {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw TrackpadRuleSetImportError.unsupportedSchema(schemaVersion)
    }
    return settings.normalized
  }
}

enum TrackpadRuleSetImportError: LocalizedError, Equatable {
  case unsupportedSchema(Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      return "Unsupported trackpad rule schema: \(version)"
    }
  }
}

enum TrackpadContactState: Int32, Codable {
  case unknown = 0
  case make = 1
  case hover = 2
  case begin = 3
  case touch = 4
  case hold = 5
  case breakContact = 6
  case out = 7

  var isEnding: Bool { self == .breakContact || self == .out }
  var isActive: Bool { self != .unknown && !isEnding }
  var isTouching: Bool {
    switch self {
    case .make, .begin, .touch, .hold: return true
    case .unknown, .hover, .breakContact, .out: return false
    }
  }
}

struct TrackpadContact: Equatable, Identifiable {
  var id: Int32
  var state: TrackpadContactState
  var position: TrackpadPoint
  var velocity: TrackpadPoint
  var size: Double
  var density: Double
  var majorAxis: Double
  var minorAxis: Double

  init(
    id: Int32,
    state: TrackpadContactState,
    position: TrackpadPoint,
    velocity: TrackpadPoint = TrackpadPoint(x: 0, y: 0),
    size: Double = 0,
    density: Double = 0,
    majorAxis: Double = 0,
    minorAxis: Double = 0
  ) {
    self.id = id
    self.state = state
    self.position = position.clamped
    self.velocity = velocity
    self.size = size
    self.density = density
    self.majorAxis = majorAxis
    self.minorAxis = minorAxis
  }
}

struct TrackpadFrame: Equatable {
  var deviceID: UInt64
  var isBuiltIn: Bool
  var timestamp: TimeInterval
  var frameNumber: Int32
  var contacts: [TrackpadContact]
}

/// What the engine decided should happen, with everything the dispatcher needs and nothing
/// else. Carrying the rule itself would let any later stage re-interpret a configuration
/// the engine has already finished reading.
struct TrackpadGestureMatch: Equatable, Identifiable {
  var id: UInt64
  var ruleID: UUID
  /// Reported as the recognized gesture; the settings pane localizes preset names.
  var ruleName: String
  var action: TrackpadGestureAction
  var activatesWindowUnderPointer: Bool
  /// What this gesture family needs suppressed, so dispatch never re-reads the trigger.
  var suppressionNeed: TrackpadInputSuppressionNeed
  /// True when this is the ordinary contact tap the click suppressor is waiting on before
  /// it drops the physical click.
  var confirmsSuppressedClick: Bool
  var direction: TrackpadDirection?
  /// Signed quantized movement for continuous actions. Discrete actions use zero.
  var continuousDelta: Double
  var timestamp: TimeInterval

  /// Projects a matched rule into an execution intent. This is the only place a rule
  /// becomes a match.
  init(
    id: UInt64,
    rule: TrackpadGestureRule,
    direction: TrackpadDirection?,
    continuousDelta: Double,
    timestamp: TimeInterval
  ) {
    self.id = id
    ruleID = rule.id
    ruleName = rule.name
    action = rule.action
    activatesWindowUnderPointer = rule.activatesWindowUnderPointer
    suppressionNeed = TrackpadRecognizerRegistry.suppression(for: rule.trigger.kind)
    confirmsSuppressedClick = rule.trigger.kind == .contact && rule.trigger.contactGesture == .tap
    self.direction = direction
    self.continuousDelta = continuousDelta
    self.timestamp = timestamp
  }
}

enum TrackpadRuntimeStatus: Equatable {
  case disabled
  case starting
  case running(deviceCount: Int)
  case unsupported(String)
  case failed(String)

  var deviceCount: Int {
    if case .running(let count) = self { return count }
    return 0
  }
}
