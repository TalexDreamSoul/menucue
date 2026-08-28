import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Foundation

struct TrackpadActionExecutionResult: Equatable {
  let message: String
  let isFailure: Bool
  /// Where the user can fix this failure, when it is one they are allowed to fix.
  let settingsURL: URL?

  static func success(_ message: String) -> Self {
    Self(message: L10n.string(message), isFailure: false, settingsURL: nil)
  }

  /// A failure this file words itself: the literal is a catalog key and is translated on
  /// the way out.
  static func failure(key: String, settingsURL: URL? = nil) -> Self {
    Self(message: L10n.string(key), isFailure: true, settingsURL: settingsURL)
  }

  /// A failure another layer already worded — AppleScript's error, the workspace opener's
  /// message. It is passed through untranslated, because it is a sentence, not a key.
  static func failure(message: String, settingsURL: URL? = nil) -> Self {
    Self(message: message, isFailure: true, settingsURL: settingsURL)
  }

  static func unavailable(_ availability: ActionAvailability, fallbackReason: String) -> Self {
    Self(
      message: availability.reason ?? L10n.string(fallbackReason),
      isFailure: true,
      settingsURL: availability.settingsURL
    )
  }
}

enum TrackpadFeedbackPolicy {
  static func shouldShowHUD(
    isEnabled: Bool,
    isContinuous: Bool,
    isFailure: Bool
  ) -> Bool {
    isEnabled && (!isContinuous || isFailure)
  }
}

private enum TrackpadDirectAdjustment {
  case increment(Double)
  case decrement(Double)
  case set(Double)
  case toggleMute
}

private enum TrackpadBackendResult<Value> {
  case success(Value)
  /// A catalog key worded in this file, not a message from CoreAudio or DisplayServices —
  /// neither of those hands back anything a user could read.
  case failure(key: String)
}

private enum TrackpadWindowPlacementCommand {
  case left
  case right
  case top
  case bottom
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight
  case maximize
  case center
  case restore
}

/// Executes concrete system operations after the engine has selected one rule. It keeps
/// permission checks at action time; raw trackpad capture never reaches this class.
final class TrackpadActionExecutor {
  private let quickActionService: QuickActionService
  private let accessibilityPermissionRequester: AccessibilityPermissionRequesting
  private let brightnessController = DisplayBrightnessController()
  private let feedbackHUD = TrackpadFeedbackHUD()
  private var lastHapticTime: TimeInterval = 0
  private var restoredWindowFrames: [AXWindowIdentity: AXWindowFrame] = [:]

  init(
    quickActionService: QuickActionService,
    accessibilityPermissionRequester: AccessibilityPermissionRequesting =
      SystemAccessibilityPermissionRequester()
  ) {
    self.quickActionService = quickActionService
    self.accessibilityPermissionRequester = accessibilityPermissionRequester
  }

  /// Whether an action could run right now, in the shape the Quick Actions panel already
  /// reports. Callers that only need to explain a failure read `reason` and `settingsURL`.
  func availability(for action: TrackpadGestureAction) -> ActionAvailability {
    availability(for: action, accessibilityStatus: accessibilityPermissionRequester.status)
  }

  /// The same answer for a whole rule list, reading the permission state once instead of
  /// once per rule. The settings pane asks on every frame it redraws.
  func availabilities(for actions: [TrackpadGestureAction]) -> [ActionAvailability] {
    let status = accessibilityPermissionRequester.status
    return actions.map { availability(for: $0, accessibilityStatus: status) }
  }

  private func availability(
    for action: TrackpadGestureAction,
    accessibilityStatus: AccessibilityPermissionStatus
  ) -> ActionAvailability {
    guard action.kind != .quickAction else {
      guard let reference = QuickActionReference(storageValue: action.quickActionStorageValue) else {
        return .unavailable(L10n.string("The selected Quick Action is no longer available."))
      }
      return quickActionService.item(for: reference).state.availability
    }
    return availability(forActionKind: action.kind, accessibilityStatus: accessibilityStatus)
  }

  private func availability(
    forActionKind kind: TrackpadGestureActionKind,
    accessibilityStatus: AccessibilityPermissionStatus
  ) -> ActionAvailability {
    ActionCatalog.availability(
      for: ActionCatalog.requirement(forActionKind: kind),
      accessibilityStatus: accessibilityStatus,
      accessibilitySettingsURL: accessibilityPermissionRequester.accessibilitySettingsURL
    )
  }

  func execute(
    _ action: TrackpadGestureAction,
    feedbackHUDEnabled: Bool,
    hapticFeedbackEnabled: Bool,
    continuous: Bool,
    continuousDelta: Double = 0
  ) -> TrackpadActionExecutionResult {
    let result: TrackpadActionExecutionResult
    switch action.kind {
    case .systemControl:
      result = executeSystemControl(action.systemControl, continuousDelta: continuousDelta)
    case .quickAction:
      result = performQuickAction(storageValue: action.quickActionStorageValue)
    case .keyboardShortcut:
      result = performKeyboardShortcut(
        keyCode: action.keyboardShortcut.keyCode,
        modifiers: eventFlags(for: action.keyboardShortcut.modifiers)
      )
    case .mouse:
      result = performMouseClick(button: mouseButton(for: action.mouseAction))
    case .scroll:
      result = performScroll(direction: action.scrollDirection)
    case .open:
      result = executeOpenTarget(kind: action.openTargetKind, target: action.target)
    case .appleScript:
      result = performAppleScript(action.appleScript)
    case .window:
      result = executeWindowAction(action.windowAction)
    case .none:
      result = .failure(key: "This gesture has no action assigned.")
    }
    present(
      result,
      feedbackHUDEnabled: feedbackHUDEnabled,
      hapticFeedbackEnabled: hapticFeedbackEnabled,
      continuous: continuous
    )
    return result
  }

  private func executeSystemControl(
    _ control: TrackpadSystemControl,
    continuousDelta: Double
  ) -> TrackpadActionExecutionResult {
    switch control {
    case .volumeUp:
      return adjustVolume(.increment(0.05))
    case .volumeDown:
      return adjustVolume(.decrement(0.05))
    case .toggleMute:
      return adjustVolume(.toggleMute)
    case .brightnessUp:
      return adjustBrightness(.increment(0.05))
    case .brightnessDown:
      return adjustBrightness(.decrement(0.05))
    case .continuousVolume:
      return adjustVolume(continuousAdjustment(for: continuousDelta))
    case .continuousBrightness:
      return adjustBrightness(continuousAdjustment(for: continuousDelta))
    }
  }

  private func continuousAdjustment(for delta: Double) -> TrackpadDirectAdjustment {
    let amount = max(0.01, min(0.2, abs(delta) * 0.035))
    return delta < 0 ? .decrement(amount) : .increment(amount)
  }

  private func eventFlags(for modifiers: Set<TrackpadModifier>) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers.contains(.command) { flags.insert(.maskCommand) }
    if modifiers.contains(.option) { flags.insert(.maskAlternate) }
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
    return flags
  }

  private func mouseButton(for action: TrackpadMouseAction) -> CGMouseButton {
    switch action {
    case .leftClick: return .left
    case .rightClick: return .right
    case .middleClick: return .center
    }
  }

  private func performScroll(direction: TrackpadDirection) -> TrackpadActionExecutionResult {
    switch direction {
    case .up: return performScroll(deltaX: 0, deltaY: 48)
    case .down: return performScroll(deltaX: 0, deltaY: -48)
    case .left: return performScroll(deltaX: -48, deltaY: 0)
    case .right: return performScroll(deltaX: 48, deltaY: 0)
    }
  }

  private func executeOpenTarget(
    kind: TrackpadOpenTargetKind,
    target: String
  ) -> TrackpadActionExecutionResult {
    switch kind {
    case .application:
      return openApplication(bundleIdentifier: target)
    case .url:
      return openURL(string: target)
    case .file:
      return openFileSystemItem(path: target, requiresDirectory: false)
    case .folder:
      return openFileSystemItem(path: target, requiresDirectory: true)
    }
  }

  private func executeWindowAction(_ action: TrackpadWindowAction) -> TrackpadActionExecutionResult {
    switch action {
    case .leftHalf: return placeFocusedWindow(.left)
    case .rightHalf: return placeFocusedWindow(.right)
    case .topHalf: return placeFocusedWindow(.top)
    case .bottomHalf: return placeFocusedWindow(.bottom)
    case .topLeftQuarter: return placeFocusedWindow(.topLeft)
    case .topRightQuarter: return placeFocusedWindow(.topRight)
    case .bottomLeftQuarter: return placeFocusedWindow(.bottomLeft)
    case .bottomRightQuarter: return placeFocusedWindow(.bottomRight)
    case .maximize: return placeFocusedWindow(.maximize)
    case .center: return placeFocusedWindow(.center)
    case .restore: return placeFocusedWindow(.restore)
    case .nextDisplay: return moveFocusedWindowToNextDisplay()
    }
  }

  func performQuickAction(storageValue: String) -> TrackpadActionExecutionResult {
    guard let reference = QuickActionReference(storageValue: storageValue) else {
      return .failure(key: "The selected Quick Action is no longer available.")
    }
    let item = quickActionService.item(for: reference)
    guard item.state.availability.isAvailable else {
      return .unavailable(
        item.state.availability,
        fallbackReason: "This Quick Action is unavailable."
      )
    }
    quickActionService.perform(reference)
    return .success(L10n.format("Ran %@.", item.title))
  }

  func performKeyboardShortcut(
    keyCode: UInt16,
    modifiers: CGEventFlags
  ) -> TrackpadActionExecutionResult {
    if let denial = accessibilityDenial(for: .keyboardShortcut) { return denial }
    guard
      let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
    else {
      return .failure(key: "macOS could not create the keyboard shortcut event.")
    }
    keyDown.flags = modifiers
    keyUp.flags = modifiers
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return .success("Sent keyboard shortcut.")
  }

  func performMouseClick(button: CGMouseButton = .left) -> TrackpadActionExecutionResult {
    if let denial = accessibilityDenial(for: .mouse) { return denial }
    let point = CGEvent(source: nil)?.location ?? .zero
    let downType: CGEventType
    let upType: CGEventType
    switch button {
    case .left:
      downType = .leftMouseDown
      upType = .leftMouseUp
    case .right:
      downType = .rightMouseDown
      upType = .rightMouseUp
    default:
      downType = .otherMouseDown
      upType = .otherMouseUp
    }
    guard
      let mouseDown = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
      let mouseUp = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
    else {
      return .failure(key: "macOS could not create the mouse click event.")
    }
    mouseDown.post(tap: .cghidEventTap)
    mouseUp.post(tap: .cghidEventTap)
    return .success("Sent mouse click.")
  }

  func performScroll(deltaX: Int32, deltaY: Int32) -> TrackpadActionExecutionResult {
    if let denial = accessibilityDenial(for: .scroll) { return denial }
    guard let event = CGEvent(
      scrollWheelEvent2Source: nil,
      units: .pixel,
      wheelCount: 2,
      wheel1: deltaY,
      wheel2: deltaX,
      wheel3: 0
    ) else {
      return .failure(key: "macOS could not create the scroll event.")
    }
    event.post(tap: .cghidEventTap)
    return .success("Sent mouse scroll.")
  }

  func performAppleScript(_ source: String) -> TrackpadActionExecutionResult {
    switch AppleScriptRunner.run(source) {
    case .success:
      return .success("Ran AppleScript.")
    case .failure(let failure):
      return .failure(message: failure.message)
    }
  }

  func openURL(string: String) -> TrackpadActionExecutionResult {
    opened(WorkspaceOpener.open(urlString: string))
  }

  func openApplication(bundleIdentifier: String) -> TrackpadActionExecutionResult {
    opened(WorkspaceOpener.openApplication(bundleIdentifier: bundleIdentifier))
  }

  func openFileSystemItem(path: String, requiresDirectory: Bool?) -> TrackpadActionExecutionResult {
    opened(WorkspaceOpener.openFileSystemItem(path: path, requiresDirectory: requiresDirectory))
  }

  private func opened(
    _ result: Result<String, WorkspaceOpener.Failure>
  ) -> TrackpadActionExecutionResult {
    switch result {
    case .success(let name):
      return .success(L10n.format("Opened %@.", name))
    case .failure(let failure):
      return .failure(message: failure.message)
    }
  }

  private func adjustVolume(_ adjustment: TrackpadDirectAdjustment) -> TrackpadActionExecutionResult {
    switch CoreAudioOutputController.apply(adjustment) {
    case .success(let observed):
      return .success(observed.message)
    case .failure(let reasonKey):
      return .failure(key: reasonKey)
    }
  }

  private func adjustBrightness(_ adjustment: TrackpadDirectAdjustment) -> TrackpadActionExecutionResult {
    switch brightnessController.apply(adjustment) {
    case .success(let observed):
      return .success(observed.message)
    case .failure(let reasonKey):
      return .failure(key: reasonKey)
    }
  }

  func activateWindowUnderPointer() -> TrackpadActionExecutionResult {
    let cocoaPoint = NSEvent.mouseLocation
    let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? cocoaPoint.y
    let point = CGPoint(x: cocoaPoint.x, y: desktopTop - cocoaPoint.y)
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return .failure(key: "macOS could not inspect windows under the pointer.")
    }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    for window in windows {
      guard
        let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        ownerPID != ownPID,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let x = (bounds["X"] as? NSNumber)?.doubleValue,
        let y = (bounds["Y"] as? NSNumber)?.doubleValue,
        let width = (bounds["Width"] as? NSNumber)?.doubleValue,
        let height = (bounds["Height"] as? NSNumber)?.doubleValue,
        width > 0,
        height > 0
      else { continue }
      let frame = CGRect(x: x, y: y, width: width, height: height)
      guard frame.contains(point) else { continue }
      guard let application = NSRunningApplication(processIdentifier: ownerPID) else { continue }
      guard application.activate(options: [.activateIgnoringOtherApps]) else { continue }
      let name = application.localizedName ?? L10n.string("the window under the pointer")
      return .success(L10n.format("Activated %@.", name))
    }
    return .failure(key: "No activatable window is under the pointer.")
  }

  private func placeFocusedWindow(_ placement: TrackpadWindowPlacementCommand) -> TrackpadActionExecutionResult {
    if let denial = accessibilityDenial(for: .window) { return denial }
    guard let focused = focusedWindow() else {
      return .failure(key: "macOS could not find a focused window to place.")
    }
    guard let currentFrame = focused.frame else {
      return .failure(key: "macOS could not read the focused window frame.")
    }
    let identity = AXWindowIdentity(pid: focused.pid, window: focused.window)

    if placement == .restore {
      guard let restored = restoredWindowFrames[identity] else {
        return .failure(key: "No previous window placement is available to restore.")
      }
      let result = setWindowFrame(restored, for: focused.window)
      restoredWindowFrames.removeValue(forKey: identity)
      return result
    }

    guard let screen = screenUnderPointer() else {
      return .failure(key: "No supported display is under the pointer.")
    }
    restoredWindowFrames[identity] = currentFrame
    let target = targetFrame(for: placement, visibleFrame: screen.visibleFrame, current: currentFrame)
    let result = setWindowFrame(target, for: focused.window)
    if result.isFailure {
      restoredWindowFrames.removeValue(forKey: identity)
    }
    return result
  }

  private func moveFocusedWindowToNextDisplay() -> TrackpadActionExecutionResult {
    if let denial = accessibilityDenial(for: .window) { return denial }
    guard let focused = focusedWindow(), let currentFrame = focused.frame else {
      return .failure(key: "macOS could not read the focused window frame.")
    }
    let screens = NSScreen.screens.sorted { lhs, rhs in
      lhs.frame.minX == rhs.frame.minX ? lhs.frame.minY < rhs.frame.minY : lhs.frame.minX < rhs.frame.minX
    }
    guard screens.count > 1 else {
      return .failure(key: "No second display is connected.")
    }
    let pointer = NSEvent.mouseLocation
    let currentIndex = screens.firstIndex { $0.frame.contains(pointer) } ?? 0
    let targetScreen = screens[(currentIndex + 1) % screens.count]
    let identity = AXWindowIdentity(pid: focused.pid, window: focused.window)
    restoredWindowFrames[identity] = currentFrame
    let size = NSSize(
      width: min(currentFrame.size.width, targetScreen.visibleFrame.width),
      height: min(currentFrame.size.height, targetScreen.visibleFrame.height)
    )
    let target = NSRect(
      x: targetScreen.visibleFrame.midX - size.width / 2,
      y: targetScreen.visibleFrame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
    let result = setWindowFrame(.fromAppKit(target), for: focused.window)
    if result.isFailure {
      restoredWindowFrames.removeValue(forKey: identity)
    }
    return result
  }

  func present(
    _ result: TrackpadActionExecutionResult,
    feedbackHUDEnabled: Bool,
    hapticFeedbackEnabled: Bool,
    continuous: Bool
  ) {
    if TrackpadFeedbackPolicy.shouldShowHUD(
      isEnabled: feedbackHUDEnabled,
      isContinuous: continuous,
      isFailure: result.isFailure
    ) {
      feedbackHUD.show(result.message, isFailure: result.isFailure)
    }
    guard hapticFeedbackEnabled, !result.isFailure else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let interval = continuous ? 0.15 : 0
    guard now - lastHapticTime >= interval else { return }
    lastHapticTime = now
    MenuCueHaptics.performAlignment()
  }

  /// Action-time permission check. It never prompts: a gesture is not an explicit request
  /// for Accessibility access, so a denial reports where to grant it instead.
  private func accessibilityDenial(
    for kind: TrackpadGestureActionKind
  ) -> TrackpadActionExecutionResult? {
    let availability = availability(
      forActionKind: kind,
      accessibilityStatus: accessibilityPermissionRequester.status
    )
    guard !availability.isAvailable else { return nil }
    return .unavailable(availability, fallbackReason: "This action is unavailable.")
  }

  private func focusedWindow() -> (window: AXUIElement, pid: pid_t, frame: AXWindowFrame?)? {
    let systemWide = AXUIElementCreateSystemWide()
    var applicationValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedApplicationAttribute as CFString,
        &applicationValue
      ) == .success,
      let applicationValue,
      CFGetTypeID(applicationValue) == AXUIElementGetTypeID()
    else { return nil }
    let application = unsafeBitCast(applicationValue, to: AXUIElement.self)

    var windowValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &windowValue
      ) == .success,
      let windowValue,
      CFGetTypeID(windowValue) == AXUIElementGetTypeID()
    else { return nil }
    let window = unsafeBitCast(windowValue, to: AXUIElement.self)

    var pid: pid_t = 0
    guard AXUIElementGetPid(application, &pid) == .success else { return nil }
    return (window, pid, windowFrame(for: window))
  }

  private func windowFrame(for window: AXUIElement) -> AXWindowFrame? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
      let positionValue,
      let sizeValue,
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
    let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)

    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionAXValue, .cgPoint, &position),
      AXValueGetValue(sizeAXValue, .cgSize, &size),
      size.width > 0,
      size.height > 0
    else { return nil }
    return AXWindowFrame(position: position, size: size)
  }

  private func setWindowFrame(
    _ frame: AXWindowFrame,
    for window: AXUIElement
  ) -> TrackpadActionExecutionResult {
    var position = frame.position
    var size = frame.size
    guard
      let positionValue = AXValueCreate(.cgPoint, &position),
      let sizeValue = AXValueCreate(.cgSize, &size),
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
      let observed = windowFrame(for: window),
      observed.matches(frame)
    else {
      return .failure(key: "macOS did not apply the requested window placement.")
    }
    return .success("Placed focused window.")
  }

  private func targetFrame(
    for placement: TrackpadWindowPlacementCommand,
    visibleFrame: NSRect,
    current: AXWindowFrame
  ) -> AXWindowFrame {
    let halfWidth = visibleFrame.width / 2
    let halfHeight = visibleFrame.height / 2
    let appKitFrame: NSRect
    switch placement {
    case .left:
      appKitFrame = NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
    case .right:
      appKitFrame = NSRect(x: visibleFrame.midX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
    case .top:
      appKitFrame = NSRect(x: visibleFrame.minX, y: visibleFrame.midY, width: visibleFrame.width, height: halfHeight)
    case .bottom:
      appKitFrame = NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfHeight)
    case .topLeft:
      appKitFrame = NSRect(x: visibleFrame.minX, y: visibleFrame.midY, width: halfWidth, height: halfHeight)
    case .topRight:
      appKitFrame = NSRect(x: visibleFrame.midX, y: visibleFrame.midY, width: halfWidth, height: halfHeight)
    case .bottomLeft:
      appKitFrame = NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: halfHeight)
    case .bottomRight:
      appKitFrame = NSRect(x: visibleFrame.midX, y: visibleFrame.minY, width: halfWidth, height: halfHeight)
    case .maximize:
      appKitFrame = visibleFrame
    case .center:
      let size = NSSize(
        width: min(current.size.width, visibleFrame.width),
        height: min(current.size.height, visibleFrame.height)
      )
      appKitFrame = NSRect(
        x: visibleFrame.midX - size.width / 2,
        y: visibleFrame.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
    case .restore:
      appKitFrame = visibleFrame
    }
    return AXWindowFrame.fromAppKit(appKitFrame)
  }

  private func screenUnderPointer() -> NSScreen? {
    let point = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(point) }
  }
}

private struct AXWindowIdentity: Hashable {
  let pid: pid_t
  let elementHash: CFHashCode

  init(pid: pid_t, window: AXUIElement) {
    self.pid = pid
    elementHash = CFHash(window)
  }
}

private struct AXWindowFrame {
  let position: CGPoint
  let size: CGSize

  static func fromAppKit(_ frame: NSRect) -> Self {
    let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? frame.maxY
    return Self(
      position: CGPoint(x: frame.minX, y: desktopTop - frame.maxY),
      size: frame.size
    )
  }

  func matches(_ other: Self, tolerance: CGFloat = 1) -> Bool {
    abs(position.x - other.position.x) <= tolerance
      && abs(position.y - other.position.y) <= tolerance
      && abs(size.width - other.size.width) <= tolerance
      && abs(size.height - other.size.height) <= tolerance
  }
}

private enum CoreAudioOutputController {
  struct ObservedVolume {
    let scalar: Float32
    let muted: Bool
    var message: String {
      muted
        ? L10n.string("Muted output")
        : L10n.format("Volume %d%%", Int((scalar * 100).rounded()))
    }
  }

  static func apply(_ adjustment: TrackpadDirectAdjustment) -> TrackpadBackendResult<ObservedVolume> {
    guard let device = defaultOutputDevice() else {
      return .failure(key: "macOS could not find a default audio output device.")
    }

    switch adjustment {
    case .toggleMute:
      guard let muted = readMute(device: device) else {
        return .failure(key: "The default audio output does not expose a mute control.")
      }
      guard setMute(!muted, device: device), let observed = readMute(device: device) else {
        return .failure(key: "macOS did not apply the requested mute state.")
      }
      let scalar = readVolume(device: device) ?? 0
      return .success(ObservedVolume(scalar: scalar, muted: observed))

    case .increment(let amount), .decrement(let amount), .set(let amount):
      guard amount.isFinite else {
        return .failure(key: "The requested volume value is invalid.")
      }
      guard let current = readVolume(device: device) else {
        return .failure(key: "The default audio output does not expose a master volume control.")
      }
      let requested: Float32
      switch adjustment {
      case .increment:
        requested = min(1, current + Float32(abs(amount)))
      case .decrement:
        requested = max(0, current - Float32(abs(amount)))
      case .set:
        requested = Float32(min(max(amount, 0), 1))
      case .toggleMute:
        requested = current
      }
      guard let observed = setVolume(requested, device: device) else {
        return .failure(key: "macOS did not apply the requested volume.")
      }
      return .success(ObservedVolume(scalar: observed, muted: readMute(device: device) ?? false))
    }
  }

  private static func defaultOutputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device
    ) == noErr, device != kAudioObjectUnknown else { return nil }
    return device
  }

  private static func virtualVolumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func physicalVolumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: element
    )
  }

  private static func volumeAddresses(device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
    let preferred = [
      virtualVolumeAddress(),
      physicalVolumeAddress(element: kAudioObjectPropertyElementMain),
    ]
    for address in preferred where canReadAndSet(address, device: device) {
      return [address]
    }
    return (1...32).compactMap { channel in
      let address = physicalVolumeAddress(element: AudioObjectPropertyElement(channel))
      return canReadAndSet(address, device: device) ? address : nil
    }
  }

  private static func canReadAndSet(
    _ candidate: AudioObjectPropertyAddress,
    device: AudioDeviceID
  ) -> Bool {
    var address = candidate
    guard AudioObjectHasProperty(device, &address) else { return false }
    var isSettable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr,
      isSettable.boolValue
    else { return false }
    return readScalar(address: address, device: device) != nil
  }

  private static func readScalar(
    address candidate: AudioObjectPropertyAddress,
    device: AudioDeviceID
  ) -> Float32? {
    var address = candidate
    var scalar: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr,
      scalar.isFinite
    else { return nil }
    return scalar
  }

  private static func setScalar(
    _ scalar: Float32,
    address candidate: AudioObjectPropertyAddress,
    device: AudioDeviceID
  ) -> Bool {
    var address = candidate
    var requested = scalar
    let size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, &requested) == noErr
  }

  private static func readVolume(device: AudioDeviceID) -> Float32? {
    let values = volumeAddresses(device: device).compactMap { address in
      readScalar(address: address, device: device)
    }
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Float32(values.count)
  }

  private static func setVolume(_ scalar: Float32, device: AudioDeviceID) -> Float32? {
    let addresses = volumeAddresses(device: device)
    let originals = addresses.compactMap { address -> (AudioObjectPropertyAddress, Float32)? in
      guard let value = readScalar(address: address, device: device) else { return nil }
      return (address, value)
    }
    guard !originals.isEmpty, originals.count == addresses.count else { return nil }
    var changed: [(AudioObjectPropertyAddress, Float32)] = []
    for (address, original) in originals {
      guard setScalar(scalar, address: address, device: device) else {
        for (changedAddress, changedOriginal) in changed {
          _ = setScalar(changedOriginal, address: changedAddress, device: device)
        }
        return nil
      }
      changed.append((address, original))
    }

    let observed = addresses.compactMap { address in
      readScalar(address: address, device: device)
    }
    guard observed.count == addresses.count,
      observed.allSatisfy({ abs($0 - scalar) <= 0.02 })
    else {
      for (address, original) in originals {
        _ = setScalar(original, address: address, device: device)
      }
      return nil
    }
    return observed.reduce(0, +) / Float32(observed.count)
  }

  private static func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func readMute(device: AudioDeviceID) -> Bool? {
    var address = muteAddress()
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
      return nil
    }
    return muted != 0
  }

  private static func setMute(_ muted: Bool, device: AudioDeviceID) -> Bool {
    var address = muteAddress()
    var isSettable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr, isSettable.boolValue else {
      return false
    }
    var requested: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, &requested) == noErr
  }
}

private final class DisplayBrightnessController {
  fileprivate static let frameworkPath =
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

  private var symbols: DisplayServicesSymbols?

  deinit {
    symbols = nil
  }

  func apply(_ adjustment: TrackpadDirectAdjustment) -> TrackpadBackendResult<ObservedBrightness> {
    guard case .toggleMute = adjustment else {
      return applyBrightness(adjustment)
    }
    return .failure(key: "Mute is not a display brightness action.")
  }

  private func applyBrightness(_ adjustment: TrackpadDirectAdjustment) -> TrackpadBackendResult<ObservedBrightness> {
    guard let displayID = displayUnderPointer() else {
      return .failure(key: "No supported display is under the pointer.")
    }
    guard let symbols = loadSymbols() else {
      return .failure(key: "Display brightness control is unavailable on this Mac.")
    }
    guard let current = symbols.brightness(displayID) else {
      return .failure(key: "The display under the pointer does not expose brightness control.")
    }

    let requested: Float
    switch adjustment {
    case .increment(let amount):
      guard amount.isFinite else { return .failure(key: "The requested brightness value is invalid.") }
      requested = min(1, current + Float(abs(amount)))
    case .decrement(let amount):
      guard amount.isFinite else { return .failure(key: "The requested brightness value is invalid.") }
      requested = max(0, current - Float(abs(amount)))
    case .set(let amount):
      guard amount.isFinite else { return .failure(key: "The requested brightness value is invalid.") }
      requested = Float(min(max(amount, 0), 1))
    case .toggleMute:
      return .failure(key: "Mute is not a display brightness action.")
    }

    guard symbols.setBrightness(requested, displayID: displayID), let observed = symbols.brightness(displayID) else {
      return .failure(key: "macOS did not apply the requested display brightness.")
    }
    guard abs(observed - requested) <= 0.02 else {
      return .failure(key: "The display reported a different brightness after the change.")
    }
    return .success(ObservedBrightness(value: observed))
  }

  private func loadSymbols() -> DisplayServicesSymbols? {
    if let symbols { return symbols }
    let loaded = DisplayServicesSymbols.load()
    symbols = loaded
    return loaded
  }

  private func displayUnderPointer() -> CGDirectDisplayID? {
    let point = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else { return nil }
    return CGDirectDisplayID(screenNumber.uint32Value)
  }
}

private struct ObservedBrightness {
  let value: Float

  var message: String {
    L10n.format("Brightness %d%%", Int((value * 100).rounded()))
  }
}

private typealias DisplayServicesGetBrightness = @convention(c) (
  CGDirectDisplayID,
  UnsafeMutablePointer<Float>
) -> Int32
private typealias DisplayServicesSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

private final class DisplayServicesSymbols {
  let handle: UnsafeMutableRawPointer
  let getBrightness: DisplayServicesGetBrightness
  let setBrightness: DisplayServicesSetBrightness

  private init(
    handle: UnsafeMutableRawPointer,
    getBrightness: @escaping DisplayServicesGetBrightness,
    setBrightness: @escaping DisplayServicesSetBrightness
  ) {
    self.handle = handle
    self.getBrightness = getBrightness
    self.setBrightness = setBrightness
  }

  deinit {
    dlclose(handle)
  }

  static func load() -> DisplayServicesSymbols? {
    guard let handle = dlopen(DisplayBrightnessController.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
      return nil
    }
    guard
      let getBrightness: DisplayServicesGetBrightness = symbol("DisplayServicesGetBrightness", from: handle),
      let setBrightness: DisplayServicesSetBrightness = symbol("DisplayServicesSetBrightness", from: handle)
    else {
      dlclose(handle)
      return nil
    }
    return DisplayServicesSymbols(
      handle: handle,
      getBrightness: getBrightness,
      setBrightness: setBrightness
    )
  }

  func brightness(_ displayID: CGDirectDisplayID) -> Float? {
    var value: Float = 0
    guard getBrightness(displayID, &value) == 0, value.isFinite else { return nil }
    return value
  }

  func setBrightness(_ value: Float, displayID: CGDirectDisplayID) -> Bool {
    setBrightness(displayID, value) == 0
  }

  private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) -> T? {
    guard let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }
}

