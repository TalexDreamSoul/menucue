import AppKit
import Combine
import QuartzCore
import SwiftUI

final class StatusBarController: NSObject {
  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let model: AppModel
  private let updateService: UpdateService
  private let languageService: AppLanguageService
  private var settingsWindow: NSWindow?
  private var quickEventWindow: NSWindow?
  private var timer: Timer?
  private var settingsCancellable: AnyCancellable?
  private var syncStatusCancellable: AnyCancellable?
  private var isPresentingSyncPrompt = false
  private var currentStatusClockID: String?
  private var clockSelection = StatusClockSelectionState()
  private lazy var clockRenderer = MenuBarClockRenderer(format: model.settings.menuBarFormat)
  private var interactionView: StatusItemInteractionView?
  private var accumulatedScrollDelta: CGFloat = 0
  private var didSwitchDuringGesture = false
  private var lastWheelSwitchDate = Date.distantPast
  private let preciseScrollThreshold: CGFloat = 12
  private let wheelSwitchCooldown: TimeInterval = 0.16
  private let preciseGestureResetInterval: TimeInterval = 0.35

  init(
    model: AppModel,
    updateService: UpdateService,
    languageService: AppLanguageService
  ) {
    self.model = model
    self.updateService = updateService
    self.languageService = languageService
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.popover = NSPopover()
    super.init()

    configureStatusItem()
    configurePopover()
    observeSettings()
    startTimer()
    refreshClockTitle()
  }

  deinit {
    timer?.invalidate()
  }

  private func configureStatusItem() {
    guard let button = statusItem.button else { return }
    button.wantsLayer = true
    button.imagePosition = .imageLeading
    button.toolTip = L10n.string("MenuCue Clock — scroll to switch clocks")

    let interactionView = StatusItemInteractionView(frame: button.bounds)
    interactionView.autoresizingMask = [.width, .height]
    interactionView.onPrimaryClick = { [weak self] in
      self?.togglePopover()
    }
    interactionView.onSecondaryClick = { [weak self, weak button] in
      guard let self, let button else { return }
      self.showContextMenu(relativeTo: button)
    }
    interactionView.onScroll = { [weak self] event in
      self?.handleStatusItemScroll(event)
    }
    button.addSubview(interactionView)
    self.interactionView = interactionView
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height)
    let hostingController = NSHostingController(
      rootView: StatusPopoverView(
        model: model,
        openSettings: { [weak self] in
          self?.showSettingsWindow()
        },
        openQuickActionSettings: { [weak self] in
          self?.showSettingsWindow(initialPane: .quickActions)
        },
        quitApp: {
          NSApp.terminate(nil)
        }
      )
    )
    hostingController.view.appearance = NSApp.appearance
    popover.contentViewController = hostingController
  }

  private func observeSettings() {
    settingsCancellable = model.$settings.sink { [weak self] _ in
      self?.refreshClockTitle()
    }
    syncStatusCancellable = model.preferenceSyncService.$status
      .removeDuplicates()
      .sink { [weak self] status in
        self?.handlePreferenceSyncStatus(status)
      }
  }

  private func handlePreferenceSyncStatus(_ status: PreferenceSyncStatus) {
    guard !isPresentingSyncPrompt else { return }
    switch status {
    case .needsOnboarding, .needsSourceDecision:
      DispatchQueue.main.async { [weak self] in
        self?.presentPreferenceSyncPrompt(for: status)
      }
    default:
      break
    }
  }

  private func presentPreferenceSyncPrompt(for status: PreferenceSyncStatus) {
    guard model.preferenceSyncService.status == status, !isPresentingSyncPrompt else { return }
    isPresentingSyncPrompt = true
    defer {
      isPresentingSyncPrompt = false
      let currentStatus = model.preferenceSyncService.status
      if currentStatus != status {
        handlePreferenceSyncStatus(currentStatus)
      }
    }

    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational

    switch status {
    case .needsOnboarding:
      alert.messageText = L10n.string("Sync MenuCue Settings with iCloud?")
      alert.informativeText = L10n.string(
        "Portable clock and appearance preferences can stay consistent across your Macs. Calendar access, Quick Actions, and system controls remain local."
      )
      alert.addButton(withTitle: L10n.string("Enable iCloud Sync"))
      alert.addButton(withTitle: L10n.string("Keep on This Mac"))
      let response = alert.runModal()
      model.completePreferenceSyncOnboarding(enable: response == .alertFirstButtonReturn)
    case let .needsSourceDecision(reason):
      alert.messageText = reason == .accountChanged
        ? L10n.string("iCloud Account Changed")
        : L10n.string("Choose Initial MenuCue Settings")
      alert.informativeText = status.message
      alert.addButton(withTitle: L10n.string("Use iCloud Settings"))
      alert.addButton(withTitle: L10n.string("Use This Mac's Settings"))
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        model.chooseCloudPreferenceSettings()
      } else {
        model.chooseLocalPreferenceSettings()
      }
    default:
      break
    }
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.refreshClockTitle()
      self?.model.refreshTimeDrivenState()
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func refreshClockTitle(transitionOrigin: ClockTransitionOrigin = .bottom) {
    popover.contentViewController?.view.appearance = NSApp.appearance
    settingsWindow?.contentViewController?.view.appearance = NSApp.appearance
    quickEventWindow?.contentViewController?.view.appearance = NSApp.appearance
    let now = Date()
    let clocks = model.settings.clockTimeZones
    let clock = currentStatusClock(at: now)
    let attributedTitle = NSMutableAttributedString(string: " ")
    appendClock(clock, at: now, includeLabel: clocks.count > 1, to: attributedTitle)
    attributedTitle.append(NSAttributedString(string: " ", attributes: baseTitleAttributes))
    let shouldAnimate = currentStatusClockID != nil && currentStatusClockID != clock.id
    applyStatusTitle(
      attributedTitle,
      clockID: clock.id,
      animated: shouldAnimate,
      transitionOrigin: transitionOrigin
    )
    interactionView?.frame = statusItem.button?.bounds ?? .zero
  }

  private func currentStatusClock(at date: Date) -> ClockTimeZone {
    clockSelection.removeUnavailableClockIDs(
      validClockIDs: Set(model.settings.clockTimeZones.map(\.id))
    )
    return StatusClockResolver.clock(
      in: model.settings,
      manualClockID: clockSelection.persistentClockID,
      temporarySelection: clockSelection.temporarySelection,
      at: date
    )
  }

  private var baseTitleAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
      .kern: -0.2,
      .baselineOffset: -1.5,
    ]
  }

  private var timeTitleAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
      .kern: -0.2,
      .baselineOffset: -1.5,
    ]
  }

  private func applyStatusTitle(
    _ attributedTitle: NSAttributedString,
    clockID: String,
    animated: Bool,
    transitionOrigin: ClockTransitionOrigin
  ) {
    guard let button = statusItem.button else { return }
    guard animated, let layer = button.layer else {
      button.attributedTitle = attributedTitle
      currentStatusClockID = clockID
      return
    }

    let transition = CATransition()
    transition.type = .push
    transition.subtype = transitionOrigin == .bottom ? .fromBottom : .fromTop
    transition.duration = 0.34
    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(transition, forKey: "statusClockSwitch")
    button.attributedTitle = attributedTitle
    currentStatusClockID = clockID
  }

  private func appendClock(
    _ clock: ClockTimeZone, at date: Date, includeLabel: Bool,
    to attributedTitle: NSMutableAttributedString
  ) {
    clockRenderer.update(format: model.settings.menuBarFormat)
    let rendering = clockRenderer.render(date: date, clock: clock)

    switch (rendering.dateText, rendering.segmentOrder) {
    case let (.some(dateText), .dateThenTime):
      attributedTitle.append(dateCapsuleString(dateText, flag: includeLabel ? clock.flag : nil))
      appendTimeSegment(rendering.timeText, leadingSpace: true, to: attributedTitle)
    case let (.some(dateText), .timeThenDate):
      appendTimeSegment(rendering.timeText, leadingSpace: false, to: attributedTitle)
      attributedTitle.append(NSAttributedString(string: " ", attributes: baseTitleAttributes))
      attributedTitle.append(dateCapsuleString(dateText, flag: includeLabel ? clock.flag : nil))
    case (.none, _):
      let prefix = includeLabel ? "\(clock.flag) " : ""
      appendTimeSegment("\(prefix)\(rendering.timeText)", leadingSpace: false, to: attributedTitle)
    }
  }

  private func appendTimeSegment(
    _ text: String,
    leadingSpace: Bool,
    to attributedTitle: NSMutableAttributedString
  ) {
    let prefix = leadingSpace ? " " : ""
    attributedTitle.append(
      NSAttributedString(string: "\(prefix)\(text)", attributes: timeTitleAttributes)
    )
  }

  private func dateCapsuleString(_ text: String, flag: String?) -> NSAttributedString {
    let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    let flagFont = NSFont.systemFont(ofSize: 9.0, weight: .regular)
    let horizontalPadding: CGFloat = 6
    let verticalPadding: CGFloat = 2.5
    let flagSpacing: CGFloat = flag == nil ? 0 : 3
    let dateAttributes: [NSAttributedString.Key: Any] = [
      .font: dateFont,
      .foregroundColor: NSColor.black,
      .kern: -0.2,
    ]
    let flagAttributes: [NSAttributedString.Key: Any] = [
      .font: flagFont
    ]
    let flagSize = flag.map { ($0 as NSString).size(withAttributes: flagAttributes) } ?? .zero
    let textSize = (text as NSString).size(withAttributes: dateAttributes)
    let imageSize = NSSize(
      width: ceil(flagSize.width + flagSpacing + textSize.width + horizontalPadding * 2),
      height: ceil(textSize.height + verticalPadding * 2)
    )
    let image = NSImage(size: imageSize)
    image.lockFocus()
    let capsuleRect = NSRect(origin: .zero, size: imageSize)
    NSColor.white.withAlphaComponent(isDarkAppearanceActive ? 0.92 : 0.82).setFill()
    NSBezierPath(roundedRect: capsuleRect, xRadius: 5, yRadius: 5).fill()

    var drawX = horizontalPadding
    if let flag {
      (flag as NSString).draw(
        at: NSPoint(x: drawX, y: verticalPadding + 0.5),
        withAttributes: flagAttributes
      )
      drawX += flagSize.width + flagSpacing
    }

    if let context = NSGraphicsContext.current {
      context.saveGraphicsState()
      context.compositingOperation = .clear
      (text as NSString).draw(
        at: NSPoint(x: drawX, y: verticalPadding - 0.5),
        withAttributes: dateAttributes
      )
      context.restoreGraphicsState()
    }
    image.unlockFocus()

    let attachment = NSTextAttachment()
    attachment.image = image
    let baselineOffset = round((dateFont.capHeight - imageSize.height) / 2) - 1.5
    attachment.bounds = NSRect(
      x: 0, y: baselineOffset, width: imageSize.width, height: imageSize.height)
    return NSAttributedString(attachment: attachment)
  }

  private var isDarkAppearanceActive: Bool {
    switch model.settings.appearanceMode {
    case .system:
      return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    case .light:
      return false
    case .dark:
      return true
    case .automaticByTimeZone:
      let hour =
        Calendar(identifier: .gregorian).dateComponents(
          in: model.settings.appearanceTimeZone, from: Date()
        ).hour ?? 12
      return !(7..<19).contains(hour)
    }
  }


  private func handleStatusItemScroll(_ event: NSEvent) {
    guard model.settings.clockTimeZones.count > 1 else { return }

    if event.phase.contains(.began) {
      accumulatedScrollDelta = 0
      didSwitchDuringGesture = false
    }
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      accumulatedScrollDelta = 0
      didSwitchDuringGesture = false
      return
    }
    guard event.momentumPhase.isEmpty else { return }
    let eventDate = Date()
    if event.hasPreciseScrollingDeltas, event.phase.isEmpty,
       eventDate.timeIntervalSince(lastWheelSwitchDate) >= preciseGestureResetInterval
    {
      accumulatedScrollDelta = 0
      didSwitchDuringGesture = false
    }
    guard !event.hasPreciseScrollingDeltas || !didSwitchDuringGesture else { return }

    let delta = event.scrollingDeltaY
    guard delta != 0 else { return }
    accumulatedScrollDelta += delta

    let threshold = event.hasPreciseScrollingDeltas ? preciseScrollThreshold : 1
    guard abs(accumulatedScrollDelta) >= threshold else { return }
    if !event.hasPreciseScrollingDeltas,
       eventDate.timeIntervalSince(lastWheelSwitchDate) < wheelSwitchCooldown
    {
      return
    }

    guard
      let scrollIntent = ClockCarouselScrollIntent(
        scrollingDeltaY: accumulatedScrollDelta,
        directionInvertedFromDevice: event.isDirectionInvertedFromDevice
      )
    else {
      return
    }
    selectAdjacentClock(
      step: scrollIntent.carouselStep,
      transitionOrigin: scrollIntent.transitionOrigin,
      at: eventDate
    )
    accumulatedScrollDelta = 0
    lastWheelSwitchDate = eventDate
    didSwitchDuringGesture = event.hasPreciseScrollingDeltas
  }

  private func selectAdjacentClock(
    step: Int,
    transitionOrigin: ClockTransitionOrigin,
    at date: Date
  ) {
    let clocks = model.settings.clockTimeZones
    let currentID = currentStatusClock(at: date).id
    guard let nextID = ClockCarouselNavigator.adjacentClockID(
      in: clocks,
      currentID: currentID,
      step: step
    ) else {
      return
    }
    clockSelection.selectTemporarily(
      clockID: nextID,
      at: date,
      duration: model.settings.statusBarSwitchIntervalSeconds
    )
    refreshClockTitle(transitionOrigin: transitionOrigin)
  }


  private func showContextMenu(relativeTo button: NSStatusBarButton) {
    let menu = NSMenu()
    let overviewItem = NSMenuItem(
      title: L10n.string(popover.isShown ? "Hide Overview" : "Show Overview"),
      action: #selector(togglePopoverFromMenu(_:)),
      keyEquivalent: ""
    )
    overviewItem.target = self
    menu.addItem(overviewItem)

    let settingsItem = NSMenuItem(
      title: L10n.string("Settings…"),
      action: #selector(openSettingsFromMenu(_:)),
      keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    let newEventItem = NSMenuItem(
      title: L10n.string("New Event…"),
      action: #selector(openNewEventFromMenu(_:)),
      keyEquivalent: "n"
    )
    newEventItem.target = self
    newEventItem.isEnabled =
      model.authorizationState.canReadEvents || model.authorizationState == .notDetermined
    menu.addItem(newEventItem)

    menu.addItem(NSMenuItem.separator())
    let quickItem = NSMenuItem(
      title: L10n.string("Quick Time Zone"), action: nil, keyEquivalent: "")
    menu.setSubmenu(quickTimeZoneMenu(), for: quickItem)
    menu.addItem(quickItem)

    menu.addItem(NSMenuItem.separator())
    let exitItem = NSMenuItem(
      title: L10n.string("Exit MenuCue"),
      action: #selector(exitFromMenu(_:)),
      keyEquivalent: "q"
    )
    exitItem.target = self
    menu.addItem(exitItem)

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
  }

  private func quickTimeZoneMenu() -> NSMenu {
    let menu = NSMenu()
    let autoItem = NSMenuItem(
      title: L10n.string("Auto Rotate"),
      action: #selector(clearManualClockSelection(_:)),
      keyEquivalent: ""
    )
    autoItem.target = self
    autoItem.state = clockSelection.persistentClockID == nil ? .on : .off
    menu.addItem(autoItem)
    menu.addItem(NSMenuItem.separator())

    for clock in model.settings.clockTimeZones {
      let item = NSMenuItem(
        title: "\(clock.flag) \(clock.title)", action: #selector(selectClockFromMenu(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = clock.id
      item.toolTip = clock.subtitle
      item.state = clockSelection.persistentClockID == clock.id ? .on : .off
      menu.addItem(item)
    }

    return menu
  }

  @objc private func togglePopoverFromMenu(_ sender: NSMenuItem) {
    togglePopover()
  }

  @objc private func openSettingsFromMenu(_ sender: NSMenuItem) {
    showSettingsWindow()
  }

  @objc private func openNewEventFromMenu(_ sender: NSMenuItem) {
    showQuickEventWindow()
  }

  @objc private func clearManualClockSelection(_ sender: NSMenuItem) {
    clockSelection.resumeAutomaticRotation()
    refreshClockTitle()
  }

  @objc private func selectClockFromMenu(_ sender: NSMenuItem) {
    guard let clockID = sender.representedObject as? String else { return }
    clockSelection.selectPersistently(clockID: clockID)
    refreshClockTitle()
  }

  @objc private func exitFromMenu(_ sender: NSMenuItem) {
    NSApp.terminate(nil)
  }

  private func showSettingsWindow(initialPane: SettingsPane = .overview) {
    popover.performClose(nil)
    model.refreshCalendarData()
    model.quickActionService.refreshAll()

    let hostingController = NSHostingController(
      rootView: SettingsWindowView(
        model: model,
        updateService: updateService,
        languageService: languageService,
        initialPane: initialPane
      )
    )
    hostingController.view.appearance = NSApp.appearance

    let window: NSWindow
    if let settingsWindow {
      window = settingsWindow
      window.contentViewController = hostingController
    } else {
      window = makeSettingsWindow(hostingController: hostingController)
      settingsWindow = window
    }

    window.contentViewController?.view.appearance = NSApp.appearance
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makeSettingsWindow(
    hostingController: NSHostingController<SettingsWindowView>
  ) -> NSWindow {
    let window = NSWindow(contentViewController: hostingController)
    window.title = L10n.string("MenuCue Settings")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.tabbingMode = .disallowed
    window.setContentSize(NSSize(width: 760, height: 640))
    window.minSize = NSSize(width: 700, height: 520)
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("MenuCueSettingsWindow")
    return window
  }

  private func showQuickEventWindow() {
    if model.authorizationState == .notDetermined {
      model.requestCalendarAccess()
      return
    }
    guard model.authorizationState.canReadEvents else { return }
    popover.performClose(nil)
    model.refreshCalendarData()

    let hostingController = NSHostingController(
      rootView: QuickEventWindowView(model: model) { [weak self] in
        self?.quickEventWindow?.close()
      }
    )
    hostingController.view.appearance = NSApp.appearance

    let window = quickEventWindow ?? NSWindow(contentViewController: hostingController)
    if quickEventWindow != nil {
      window.contentViewController = hostingController
    } else {
      window.title = L10n.string("New Event")
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      quickEventWindow = window
    }
    window.contentViewController?.view.appearance = NSApp.appearance
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func togglePopover() {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      showPopover()
    }
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    model.refreshCalendarData()
    model.quickActionService.refreshAll()
    refreshClockTitle()
    if !popover.isShown {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    NSApp.activate(ignoringOtherApps: true)
  }
}
