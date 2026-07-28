import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

private struct QuickActionProcessResult {
  let status: Int32
  let standardOutput: String
  let standardError: String
}

private enum QuickActionExecutionError: LocalizedError {
  case missingExecutable(String)
  case processFailed(String)
  case permissionRequired(String)
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .missingExecutable(let path):
      return "Required system tool is unavailable: \(path)"
    case .processFailed(let message), .permissionRequired(let message), .unavailable(let message):
      return message
    }
  }
}

final class QuickActionService: ObservableObject {
  @Published private(set) var states: [BuiltInQuickActionID: QuickActionState]
  @Published private(set) var shortcuts: [String] = []
  @Published private(set) var feedbackMessage: String?

  private let appearanceService: AppearanceService
  let powerHelperManager: PowerHelperManager
  private var keepAwakeProcess: Process?
  private var appearanceObserver: NSObjectProtocol?
  private let cleaningController = CleaningModeController()
  private var cancellables: Set<AnyCancellable> = []

  init(appearanceService: AppearanceService) {
    self.appearanceService = appearanceService
    self.powerHelperManager = PowerHelperManager()
    self.states = Dictionary(
      uniqueKeysWithValues: BuiltInQuickActionID.allCases.map { ($0, .available) }
    )
    cleaningController.onStateChange = { [weak self] in
      self?.refreshCleaningStates()
    }
    appearanceObserver = DistributedNotificationCenter.default.addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self?.refreshDarkModeState()
      }
    }
    powerHelperManager.objectWillChange
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.refreshPowerStates()
        }
      }
      .store(in: &cancellables)
    refreshAll()
  }

  deinit {
    if let appearanceObserver {
      DistributedNotificationCenter.default.removeObserver(appearanceObserver)
    }
    keepAwakeProcess?.terminate()
    cleaningController.stop()
  }

  var catalogItems: [QuickActionItem] {
    let builtIns = BuiltInQuickActionID.allCases.map { item(for: .builtIn($0)) }
    let shortcutItems = shortcuts.map { item(for: .shortcut($0)) }
    return builtIns + shortcutItems
  }

  func pinnedItems(for references: [QuickActionReference]) -> [QuickActionItem] {
    references.map(item(for:))
  }

  func item(for reference: QuickActionReference) -> QuickActionItem {
    switch reference {
    case .builtIn(let actionID):
      return QuickActionItem(
        reference: reference,
        title: actionID.title,
        systemImage: actionID.systemImage,
        kind: actionID.kind,
        isDestructive: actionID.isDestructive,
        state: states[actionID] ?? .available
      )
    case .shortcut(let name):
      let exists = shortcuts.contains(name)
      let availability =
        exists
        ? QuickActionAvailability.available
        : .unavailable("This Shortcut was renamed or deleted in Apple Shortcuts.")
      return QuickActionItem(
        reference: reference,
        title: name,
        systemImage: "command.square.fill",
        kind: .button,
        isDestructive: false,
        state: QuickActionState(
          availability: availability,
          isOn: nil,
          isRunning: false
        )
      )
    }
  }

  func isAvailable(_ reference: QuickActionReference) -> Bool {
    item(for: reference).state.availability.isAvailable
  }

  func refreshAll() {
    powerHelperManager.refreshStatus()
    refreshImmediateStates()
    DispatchQueue.global(qos: .utility).async {
      let snapshot = Self.loadSystemSnapshot()
      DispatchQueue.main.async { [weak self] in
        self?.apply(snapshot)
      }
    }
  }

  func perform(_ reference: QuickActionReference) {
    if case .builtIn(let actionID) = reference,
      actionID == .lowPowerMode || actionID == .preventLidSleep,
      !powerHelperManager.registrationState.isEnabled
    {
      powerHelperManager.requestRegistration()
      refreshPowerStates()
      setFeedback(powerHelperManager.registrationState.detail)
      return
    }
    let selectedItem = item(for: reference)
    guard selectedItem.state.availability.isAvailable else {
      if let settingsURL = selectedItem.state.availability.settingsURL {
        NSWorkspace.shared.open(settingsURL)
      }
      setFeedback(selectedItem.state.availability.reason ?? "This action is unavailable.")
      return
    }

    switch reference {
    case .shortcut(let name):
      performProcessBacked(reference: reference) {
        _ = try Self.runProcess("/usr/bin/shortcuts", arguments: ["run", name])
        return "Ran \(name)."
      }
    case .builtIn(let actionID):
      perform(actionID)
    }
  }

  func openRemediation(for actionID: BuiltInQuickActionID) {
    if actionID == .lowPowerMode || actionID == .preventLidSleep {
      powerHelperManager.requestRegistration()
      refreshPowerStates()
      return
    }
    guard let settingsURL = states[actionID]?.availability.settingsURL else { return }
    NSWorkspace.shared.open(settingsURL)
  }

  private func perform(_ actionID: BuiltInQuickActionID) {
    switch actionID {
    case .turnOffDisplays:
      performProcessBacked(reference: .builtIn(actionID)) {
        _ = try Self.runProcess("/usr/bin/pmset", arguments: ["displaysleepnow"])
        return "Displays are sleeping."
      }
    case .lowPowerMode:
      performPowerToggle(actionID, target: !powerHelperManager.lowPowerModeEnabled)
    case .preventLidSleep:
      let target = !powerHelperManager.sleepDisabled
      guard !target || confirmLidSleepRisk() else { return }
      performPowerToggle(actionID, target: target)
    case .hideNotch:
      let availability = states[actionID]?.availability
      if let settingsURL = availability?.settingsURL {
        NSWorkspace.shared.open(settingsURL)
      }
      setFeedback(availability?.reason ?? "This action is unavailable.")
    case .darkMode:
      let target = !(states[actionID]?.isOn ?? false)
      appearanceService.setSystemDarkMode(target)
      refreshDarkModeState()
      setFeedback(target ? "Dark Mode enabled." : "Dark Mode disabled.")
    case .lockScreen:
      performProcessBacked(reference: .builtIn(actionID)) {
        let source =
          "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        try Self.runAppleScript(source)
        return "Screen locked."
      }
    case .keepScreenOn:
      toggleKeepAwake()
    case .screenSaver:
      startScreenSaver()
    case .hideDesktopIcons:
      togglePreference(
        actionID: actionID,
        domain: "com.apple.finder",
        key: "CreateDesktop",
        processToRestart: "Finder",
        storedValueWhenOn: false
      )
    case .autoHideDock:
      togglePreference(
        actionID: actionID,
        domain: "com.apple.dock",
        key: "autohide",
        processToRestart: "Dock",
        storedValueWhenOn: true
      )
    case .autoHideMenuBar:
      togglePreference(
        actionID: actionID,
        domain: "NSGlobalDomain",
        key: "_HIHideMenuBar",
        processToRestart: "SystemUIServer",
        storedValueWhenOn: true
      )
    case .cleanScreen:
      cleaningController.start(mode: .screen)
    case .cleanKeyboard:
      guard cleaningController.start(mode: .keyboard) else {
        setFeedback("Allow Accessibility access, then try Clean Keyboard again.")
        return
      }
    case .emptyTrash:
      performProcessBacked(reference: .builtIn(actionID)) {
        let removedCount = try Self.emptyUserTrash()
        return removedCount == 1 ? "Removed 1 trash item." : "Removed \(removedCount) trash items."
      }
    }
  }

  private func toggleKeepAwake() {
    if let process = keepAwakeProcess, process.isRunning {
      process.terminate()
      keepAwakeProcess = nil
      setState(.keepScreenOn, isOn: false, isRunning: false)
      setFeedback("Keep Screen On disabled.")
      return
    }

    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/caffeinate") else {
      setFeedback("The caffeinate system tool is unavailable.")
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    process.arguments = ["-di"]
    process.terminationHandler = { [weak self, weak process] _ in
      DispatchQueue.main.async {
        guard self?.keepAwakeProcess === process else { return }
        self?.keepAwakeProcess = nil
        self?.setState(.keepScreenOn, isOn: false, isRunning: false)
      }
    }

    do {
      try process.run()
      keepAwakeProcess = process
      setState(.keepScreenOn, isOn: true, isRunning: false)
      setFeedback("Keep Screen On enabled.")
    } catch {
      setFeedback(error.localizedDescription)
    }
  }

  private func startScreenSaver() {
    let candidatePaths = [
      "/System/Library/CoreServices/ScreenSaverEngine.app",
      "/System/Library/Frameworks/ScreenSaver.framework/Versions/A/Resources/ScreenSaverEngine.app",
    ]
    guard let path = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    else {
      setFeedback("Screen Saver is unavailable on this macOS version.")
      return
    }
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: path),
      configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      DispatchQueue.main.async {
        if let error {
          self?.setFeedback(error.localizedDescription)
        }
      }
    }
  }

  private func togglePreference(
    actionID: BuiltInQuickActionID,
    domain: String,
    key: String,
    processToRestart: String,
    storedValueWhenOn: Bool
  ) {
    let currentOn = states[actionID]?.isOn ?? false
    let targetOn = !currentOn
    let storedTarget = targetOn == storedValueWhenOn
    performProcessBacked(reference: .builtIn(actionID)) {
      _ = try Self.runProcess(
        "/usr/bin/defaults",
        arguments: ["write", domain, key, "-bool", storedTarget ? "true" : "false"]
      )
      _ = try? Self.runProcess("/usr/bin/killall", arguments: [processToRestart])
      return targetOn ? "\(actionID.title) enabled." : "\(actionID.title) disabled."
    }
  }

  private func performProcessBacked(
    reference: QuickActionReference,
    operation: @escaping () throws -> String
  ) {
    setRunning(reference, true)
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let message = try operation()
        DispatchQueue.main.async { [weak self] in
          self?.setFeedback(message)
          self?.setRunning(reference, false)
          self?.refreshAll()
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.setFeedback(error.localizedDescription)
          self?.setRunning(reference, false)
          self?.refreshAll()
        }
      }
    }
  }

  private func refreshImmediateStates() {
    refreshDarkModeState()
    setState(.keepScreenOn, isOn: keepAwakeProcess?.isRunning == true, isRunning: false)
    refreshCleaningStates()

    refreshPowerStates()

    let hasNotchedDisplay = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    let notchReason =
      hasNotchedDisplay
      ? "This build has no reliable public system-wide notch-hiding mechanism."
      : "No notched built-in display is connected."
    states[.hideNotch] = QuickActionState(
      availability: .unavailable(
        notchReason,
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")
      ),
      isOn: false,
      isRunning: false
    )
  }

  private func refreshPowerStates() {
    let availability: QuickActionAvailability
    if powerHelperManager.registrationState.isEnabled {
      availability = .available
    } else {
      availability = .unavailable(powerHelperManager.registrationState.detail)
    }

    states[.lowPowerMode] = QuickActionState(
      availability: availability,
      isOn: powerHelperManager.registrationState.isEnabled
        ? powerHelperManager.lowPowerModeEnabled
        : ProcessInfo.processInfo.isLowPowerModeEnabled,
      isRunning: powerHelperManager.isWorking
    )
    states[.preventLidSleep] = QuickActionState(
      availability: availability,
      isOn: powerHelperManager.sleepDisabled,
      isRunning: powerHelperManager.isWorking
    )
  }

  private func performPowerToggle(_ actionID: BuiltInQuickActionID, target: Bool) {
    setRunning(.builtIn(actionID), true)
    let completion: (Result<Void, Error>) -> Void = { [weak self] result in
      guard let self else { return }
      self.refreshPowerStates()
      switch result {
      case .success:
        let actionName = actionID == .lowPowerMode ? "Low Power Mode" : "Don't Sleep When Closed"
        self.setFeedback("\(actionName) \(target ? "enabled" : "disabled").")
      case .failure(let error):
        self.setFeedback(error.localizedDescription)
      }
    }

    if actionID == .lowPowerMode {
      powerHelperManager.setLowPowerMode(target, completion: completion)
    } else {
      powerHelperManager.setSleepDisabled(target, completion: completion)
    }
  }

  private func confirmLidSleepRisk() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Keep Running With the Lid Closed?"
    alert.informativeText =
      "This prevents system sleep and can increase heat and battery use. Keep your Mac ventilated and do not place it in a bag while enabled."
    alert.addButton(withTitle: "Enable")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func refreshDarkModeState() {
    setState(
      .darkMode,
      isOn: appearanceService.currentSystemDarkMode ?? false,
      isRunning: false
    )
  }

  private func refreshCleaningStates() {
    setState(
      .cleanScreen,
      isOn: cleaningController.mode == .screen,
      isRunning: false
    )
    setState(
      .cleanKeyboard,
      isOn: cleaningController.mode == .keyboard,
      isRunning: false
    )
  }

  private func apply(_ snapshot: QuickActionSystemSnapshot) {
    shortcuts = snapshot.shortcuts
    setState(.hideDesktopIcons, isOn: snapshot.desktopIconsHidden, isRunning: false)
    setState(.autoHideDock, isOn: snapshot.dockAutoHidden, isRunning: false)
    setState(.autoHideMenuBar, isOn: snapshot.menuBarAutoHidden, isRunning: false)
  }

  private func setState(_ actionID: BuiltInQuickActionID, isOn: Bool?, isRunning: Bool) {
    var state = states[actionID] ?? .available
    state.isOn = isOn
    state.isRunning = isRunning
    states[actionID] = state
  }

  private func setRunning(_ reference: QuickActionReference, _ isRunning: Bool) {
    guard case .builtIn(let actionID) = reference else { return }
    var state = states[actionID] ?? .available
    state.isRunning = isRunning
    states[actionID] = state
  }

  private func setFeedback(_ message: String) {
    feedbackMessage = message
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard self?.feedbackMessage == message else { return }
      self?.feedbackMessage = nil
    }
  }

  private static func loadSystemSnapshot() -> QuickActionSystemSnapshot {
    let createDesktop = readBooleanPreference(
      domain: "com.apple.finder",
      key: "CreateDesktop",
      defaultValue: true
    )
    let dockAutoHidden = readBooleanPreference(
      domain: "com.apple.dock",
      key: "autohide",
      defaultValue: false
    )
    let menuBarAutoHidden = readBooleanPreference(
      domain: "NSGlobalDomain",
      key: "_HIHideMenuBar",
      defaultValue: false
    )
    let shortcutResult = try? runProcess("/usr/bin/shortcuts", arguments: ["list"])
    let shortcuts =
      shortcutResult?.standardOutput
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []

    return QuickActionSystemSnapshot(
      desktopIconsHidden: !createDesktop,
      dockAutoHidden: dockAutoHidden,
      menuBarAutoHidden: menuBarAutoHidden,
      shortcuts: shortcuts
    )
  }

  private static func readBooleanPreference(
    domain: String,
    key: String,
    defaultValue: Bool
  ) -> Bool {
    guard
      let result = try? runProcess(
        "/usr/bin/defaults",
        arguments: ["read", domain, key]
      ), result.status == 0
    else {
      return defaultValue
    }
    let normalized = result.standardOutput
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return ["1", "true", "yes"].contains(normalized)
  }

  private static func runProcess(
    _ executablePath: String,
    arguments: [String]
  ) throws -> QuickActionProcessResult {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw QuickActionExecutionError.missingExecutable(executablePath)
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    let result = QuickActionProcessResult(
      status: process.terminationStatus,
      standardOutput: String(decoding: outputData, as: UTF8.self),
      standardError: String(decoding: errorData, as: UTF8.self)
    )

    guard result.status == 0 else {
      let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw QuickActionExecutionError.processFailed(
        message.isEmpty
          ? "\(URL(fileURLWithPath: executablePath).lastPathComponent) failed." : message
      )
    }
    return result
  }

  private static func runAppleScript(_ source: String) throws {
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
      let message =
        error[NSAppleScript.errorMessage] as? String
        ?? "macOS denied the requested Automation action."
      throw QuickActionExecutionError.permissionRequired(message)
    }
  }

  private static func emptyUserTrash() throws -> Int {
    guard
      let trashURL = FileManager.default.urls(
        for: .trashDirectory,
        in: .userDomainMask
      ).first
    else {
      throw QuickActionExecutionError.unavailable("The user Trash folder is unavailable.")
    }

    let items = try FileManager.default.contentsOfDirectory(
      at: trashURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for item in items {
      try FileManager.default.removeItem(at: item)
    }
    return items.count
  }
}

private struct QuickActionSystemSnapshot {
  let desktopIconsHidden: Bool
  let dockAutoHidden: Bool
  let menuBarAutoHidden: Bool
  let shortcuts: [String]
}

private enum CleaningMode {
  case screen
  case keyboard
}

private final class CleaningModeController: ObservableObject {
  @Published private(set) var mode: CleaningMode?
  @Published private(set) var secondsRemaining = 0

  var onStateChange: (() -> Void)?

  private var windows: [NSWindow] = []
  private var countdownTimer: Timer?
  private var localKeyMonitor: Any?
  private var escapeHoldTimer: Timer?
  private var keyboardBlocker: KeyboardEventBlocker?

  @discardableResult
  func start(mode: CleaningMode) -> Bool {
    stop()

    if mode == .keyboard {
      let blocker = KeyboardEventBlocker()
      guard blocker.start(onEscapeHeld: { [weak self] in self?.stop() }) else {
        return false
      }
      keyboardBlocker = blocker
    } else {
      installLocalEscapeMonitor()
    }

    self.mode = mode
    secondsRemaining = 30
    windows = NSScreen.screens.map { screen in
      let window = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false,
        screen: screen
      )
      window.level = .screenSaver
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      window.backgroundColor = .black
      window.isOpaque = true
      window.hasShadow = false
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: CleaningOverlayView(controller: self, mode: mode)
      )
      window.makeKeyAndOrderFront(nil)
      return window
    }
    NSApp.activate(ignoringOtherApps: true)

    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      secondsRemaining -= 1
      if secondsRemaining <= 0 {
        stop()
      }
    }
    if let countdownTimer {
      RunLoop.main.add(countdownTimer, forMode: .common)
    }
    onStateChange?()
    return true
  }

  func stop() {
    countdownTimer?.invalidate()
    countdownTimer = nil
    escapeHoldTimer?.invalidate()
    escapeHoldTimer = nil
    keyboardBlocker?.stop()
    keyboardBlocker = nil
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    let hadMode = mode != nil
    mode = nil
    secondsRemaining = 0
    if hadMode {
      onStateChange?()
    }
  }

  private func installLocalEscapeMonitor() {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
      [weak self] event in
      guard event.keyCode == 53 else { return event }
      if event.type == .keyDown && !event.isARepeat {
        self?.startEscapeHoldTimer()
      } else if event.type == .keyUp {
        self?.escapeHoldTimer?.invalidate()
        self?.escapeHoldTimer = nil
      }
      return nil
    }
  }

  private func startEscapeHoldTimer() {
    escapeHoldTimer?.invalidate()
    escapeHoldTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
      self?.stop()
    }
  }
}

private struct CleaningOverlayView: View {
  @ObservedObject var controller: CleaningModeController
  let mode: CleaningMode

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 16) {
        Image(systemName: mode == .screen ? "sparkles.rectangle.stack" : "keyboard")
          .font(.system(size: 44, weight: .medium))
        Text(mode == .screen ? "Clean Screen" : "Clean Keyboard")
          .font(.title2.weight(.semibold))
        Text("Exits automatically in \(controller.secondsRemaining)s")
          .foregroundStyle(.secondary)
        Button("Exit Cleaning Mode") {
          controller.stop()
        }
        .keyboardShortcut(.cancelAction)
        Text("You can also hold Esc for 3 seconds.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .foregroundStyle(.white)
      .padding(28)
    }
  }
}

private final class KeyboardEventBlocker {
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var escapeHoldTimer: Timer?
  private var onEscapeHeld: (() -> Void)?

  func start(onEscapeHeld: @escaping () -> Void) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else { return false }

    self.onEscapeHeld = onEscapeHeld
    let mask =
      CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
      | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, userInfo in
          guard let userInfo else { return Unmanaged.passUnretained(event) }
          let blocker = Unmanaged<KeyboardEventBlocker>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
          return blocker.handle(type: type, event: event)
        },
        userInfo: userInfo
      )
    else {
      return false
    }

    self.eventTap = eventTap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    return true
  }

  func stop() {
    escapeHoldTimer?.invalidate()
    escapeHoldTimer = nil
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    eventTap = nil
    runLoopSource = nil
    onEscapeHeld = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if keyCode == 53 {
      if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        escapeHoldTimer?.invalidate()
        escapeHoldTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) {
          [weak self] _ in
          self?.onEscapeHeld?()
        }
      } else if type == .keyUp {
        escapeHoldTimer?.invalidate()
        escapeHoldTimer = nil
      }
    }
    return nil
  }
}
