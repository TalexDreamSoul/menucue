import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class PopoverPresentationState: ObservableObject {
  static let shared = PopoverPresentationState()
  @Published private(set) var isVisible = false

  func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
  }
}

enum StatusContextMenuItemFactory {
  @MainActor
  static func checkForUpdatesItem(
    target: AnyObject,
    action: Selector,
    isEnabled: Bool
  ) -> NSMenuItem {
    let item = NSMenuItem(
      title: L10n.string("Check for Updates"),
      action: action,
      keyEquivalent: ""
    )
    item.target = target
    item.isEnabled = isEnabled
    return item
  }
}

struct SettingsWindowDockController {
  private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool

  init(
    setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = {
      NSApp.setActivationPolicy($0)
    }
  ) {
    self.setActivationPolicy = setActivationPolicy
  }

  @MainActor
  func settingsWillShow() {
    _ = setActivationPolicy(.regular)
  }

  @MainActor
  func settingsDidClose() {
    _ = setActivationPolicy(.accessory)
  }
}

/// Every input the date capsule is drawn from. `backingScale` is part of it because the
/// capsule is rasterised at the scale of whichever display carries the menu bar.
struct DateCapsuleKey: Hashable {
  let text: String
  let flag: String?
  let isDark: Bool
  let backingScale: CGFloat
}

/// The capsule shows a date, so its content turns over roughly once a day while the clock
/// redraws every second. Keeping the rendered capsules removes a bitmap context, two text
/// measurements and two draws from the per-second path.
///
/// A hit must return the *same* `NSAttributedString` instance, not an equal one:
/// `applyStatusTitle` skips the title assignment by comparing the built title against the
/// one on the button, and the capsule rides in that title as an `NSTextAttachment`, which
/// compares by identity. Re-wrapping a cached capsule in a fresh attachment would leave
/// every title unequal and silently turn that skip off.
final class DateCapsuleCache {
  /// The status bar rotates through the configured clocks, so the working set is one entry
  /// per clock — briefly two, while a date rollover crosses time zones. Sized well past any
  /// plausible clock count, because overflowing drops the hit rate to zero rather than
  /// degrading: eviction clears the whole table, and the rotation refills it immediately.
  static let capacity = 32

  private var entries: [DateCapsuleKey: NSAttributedString] = [:]

  func string(
    for key: DateCapsuleKey,
    make: (DateCapsuleKey) -> NSAttributedString
  ) -> NSAttributedString {
    if let cached = entries[key] { return cached }
    let rendered = make(key)
    if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
    entries[key] = rendered
    return rendered
  }
}

final class StatusBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
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
  private let dateCapsuleCache = DateCapsuleCache()
  private lazy var clockRenderer = MenuBarClockRenderer(format: model.settings.menuBarFormat)
  private let settingsWindowDockController = SettingsWindowDockController()
  private var interactionView: StatusItemInteractionView?
  private var accumulatedScrollDelta: CGFloat = 0
  private var didSwitchDuringGesture = false
  private var lastWheelSwitchDate = Date.distantPast
  private let preciseScrollThreshold: CGFloat = 12
  static let wheelSwitchCooldown: TimeInterval = 0.16
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
    configurePowerMonitoring()
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
    // AppKit layers do not clip by default, so an unclipped push would slide the outgoing
    // title straight over whatever menu bar item sits next to us.
    button.layer?.masksToBounds = true
    button.imagePosition = .imageLeading
    button.toolTip = L10n.string("MenuCue Clock — scroll to switch clocks")

    let interactionView = StatusItemInteractionView(frame: button.bounds)
    interactionView.autoresizingMask = [.width, .height]
    interactionView.onPrimaryClick = { [weak self] in
      self?.togglePopover()
    }
    interactionView.onSecondaryClick = { [weak self, weak button] in
      guard let self, let button else { return }
      Task { @MainActor in
        self.showContextMenu(relativeTo: button)
      }
    }
    interactionView.onScroll = { [weak self] event in
      self?.handleStatusItemScroll(event)
    }
    button.addSubview(interactionView)
    self.interactionView = interactionView
  }

  /// Opens the popover without a click, so the swipe path can be exercised from a
  /// script. Gated on MENUCUE_SWIPE_LOG so it never runs in a shipped launch.
  func debugShowPopover() {
    guard let button = statusItem.button else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    if let win = popover.contentViewController?.view.window {
      FileHandle.standardError.write(Data("[swipe] popover window=\(win.frame)\n".utf8))
    }
  }

  /// Background wake backfill, once the user has opened the power feature.
  ///
  /// Nothing runs on a first launch — the setting defaults to false — so the app does
  /// not spawn `pmset` for a user who never looks at this.
  private func configurePowerMonitoring() {
    guard model.settings.powerMonitoringEnabled else { return }
    model.powerDiagnosticsService.startBackgroundMonitoring()
    // "What has been running" needs samples over a window, so this one accumulates
    // too — on a slower cadence, because each sample costs a second of `top`.
    model.processEnergyService.startBackgroundSampling()
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.delegate = self
    popover.contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height)
    let relay = SwipeRelay()
    let hostingController = SwipeForwardingController(
      rootView: StatusPopoverView(
        model: model,
        openSettings: { [weak self] in
          Task { @MainActor in
            self?.showSettingsWindow()
          }
        },
        openQuickActionSettings: { [weak self] in
          Task { @MainActor in
            self?.showSettingsWindow(initialPane: .quickActions)
          }
        },
        openDashboard: { [weak self] section in
          Task { @MainActor in
            self?.showSettingsWindow(initialPane: .dashboard, dashboardSection: section)
          }
        },
        quitApp: {
          NSApp.terminate(nil)
        },
        swipeRelay: relay
      ),
      relay: relay
    )
    hostingController.applyAppearance(NSApp.appearance)
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
    let appearance = NSApp.appearance
    Self.apply(appearance, to: popover.contentViewController?.view)
    Self.apply(appearance, to: settingsWindow?.contentViewController?.view)
    Self.apply(appearance, to: quickEventWindow?.contentViewController?.view)
    let now = Date()
    let clocks = model.settings.clockTimeZones
    let clock = currentStatusClock(at: now)
    let attributedTitle = NSMutableAttributedString(string: " ")
    appendClock(clock, at: now, includeLabel: clocks.count > 1, to: attributedTitle)
    attributedTitle.append(NSAttributedString(string: " ", attributes: Self.baseTitleAttributes))
    let shouldAnimate = currentStatusClockID != nil && currentStatusClockID != clock.id
    applyStatusTitle(
      attributedTitle,
      clockID: clock.id,
      animated: shouldAnimate,
      transitionOrigin: transitionOrigin
    )
    let buttonBounds = statusItem.button?.bounds ?? .zero
    if let interactionView, interactionView.frame != buttonBounds {
      interactionView.frame = buttonBounds
    }
  }

  /// Setting `appearance` re-runs the appearance walk over the whole hosted view tree even
  /// when the value is unchanged, so the per-second refresh must compare first.
  private static func apply(_ appearance: NSAppearance?, to view: NSView?) {
    guard let view, view.appearance !== appearance else { return }
    view.appearance = appearance
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

  // `labelColor` is a dynamic colour, so it still resolves against the appearance in effect
  // when the title is drawn — holding the attributes here only skips the font lookup.
  private static let baseTitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor.labelColor,
    .kern: -0.2,
    .baselineOffset: -1.5,
  ]

  private static let timeTitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold),
    .foregroundColor: NSColor.labelColor,
    .kern: -0.2,
    .baselineOffset: -1.5,
  ]

  private static let dateCapsuleFont = NSFont.monospacedDigitSystemFont(
    ofSize: 11.5, weight: .semibold)
  private static let dateCapsuleFlagFont = NSFont.systemFont(ofSize: 9.0, weight: .regular)

  private func applyStatusTitle(
    _ attributedTitle: NSAttributedString,
    clockID: String,
    animated: Bool,
    transitionOrigin: ClockTransitionOrigin
  ) {
    guard let button = statusItem.button else { return }
    // Assigning the title re-measures the cell and lays the button out again, so a refresh
    // that produced the same title has to stop here. A clock switch always changes it.
    // This comparison only holds because `DateCapsuleCache` hands back the same attributed
    // string on a hit — see the note there before changing how capsules are vended.
    guard animated || button.attributedTitle != attributedTitle else {
      currentStatusClockID = clockID
      return
    }
    let motion = MotionProfile(
      quality: model.settings.animationQuality,
      reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    guard animated, motion.statusClockMotion != .none, let layer = button.layer else {
      button.attributedTitle = attributedTitle
      currentStatusClockID = clockID
      return
    }

    let transition = CATransition()
    transition.type = .push
    transition.subtype = transitionOrigin == .bottom ? .fromBottom : .fromTop
    transition.duration = motion.statusClockTransitionDuration
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
      attributedTitle.append(NSAttributedString(string: " ", attributes: Self.baseTitleAttributes))
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
      NSAttributedString(string: "\(prefix)\(text)", attributes: Self.timeTitleAttributes)
    )
  }

  private func dateCapsuleString(_ text: String, flag: String?) -> NSAttributedString {
    let key = DateCapsuleKey(
      text: text,
      flag: flag,
      isDark: isDarkAppearanceActive,
      backingScale: statusItem.button?.window?.backingScaleFactor
        ?? NSScreen.main?.backingScaleFactor ?? 1
    )
    return dateCapsuleCache.string(for: key, make: Self.drawDateCapsule)
  }

  private static func drawDateCapsule(_ key: DateCapsuleKey) -> NSAttributedString {
    let text = key.text
    let flag = key.flag
    let dateFont = dateCapsuleFont
    let horizontalPadding: CGFloat = 6
    let verticalPadding: CGFloat = 2.5
    let flagSpacing: CGFloat = flag == nil ? 0 : 3
    let dateAttributes: [NSAttributedString.Key: Any] = [
      .font: dateFont,
      .foregroundColor: NSColor.black,
      .kern: -0.2,
    ]
    let flagAttributes: [NSAttributedString.Key: Any] = [
      .font: dateCapsuleFlagFont
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
    NSColor.white.withAlphaComponent(key.isDark ? 0.92 : 0.82).setFill()
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
       eventDate.timeIntervalSince(lastWheelSwitchDate) < Self.wheelSwitchCooldown
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


  @MainActor
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

    menu.addItem(
      StatusContextMenuItemFactory.checkForUpdatesItem(
        target: self,
        action: #selector(checkForUpdatesFromMenu(_:)),
        isEnabled: updateService.canCheckForUpdates
      )
    )

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

  @MainActor
  @objc private func openSettingsFromMenu(_ sender: NSMenuItem) {
    showSettingsWindow()
  }

  @MainActor
  @objc private func checkForUpdatesFromMenu(_ sender: NSMenuItem) {
    updateService.checkForUpdates()
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

  func popoverWillShow(_ notification: Notification) {
    PopoverPresentationState.shared.setVisible(true)
  }

  func popoverDidClose(_ notification: Notification) {
    PopoverPresentationState.shared.setVisible(false)
  }

  @MainActor
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
    settingsWindowDockController.settingsDidClose()
  }

  @MainActor
  private func showSettingsWindow(
    initialPane: SettingsPane = .overview,
    dashboardSection: DashboardSection = .cpu
  ) {
    popover.performClose(nil)
    settingsWindowDockController.settingsWillShow()
    model.refreshCalendarData()
    model.quickActionService.refreshAll()

    let relay = SwipeRelay()
    let hostingController = SwipeForwardingController(
      rootView: SettingsWindowView(
        model: model,
        updateService: updateService,
        languageService: languageService,
        initialPane: initialPane,
        initialDashboardSection: dashboardSection,
        swipeRelay: relay
      ),
      relay: relay
    )
    hostingController.applyAppearance(NSApp.appearance)

    let window: NSWindow
    if let settingsWindow {
      window = settingsWindow
      window.contentViewController = hostingController
    } else {
      window = makeSettingsWindow(hostingController: hostingController)
      settingsWindow = window
    }
    window.delegate = self

    window.contentViewController?.view.appearance = NSApp.appearance
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makeSettingsWindow(
    hostingController: SwipeForwardingController<SettingsWindowView>
  ) -> NSWindow {
    let window = NSWindow(contentViewController: hostingController)
    window.title = L10n.string("MenuCue Settings")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.tabbingMode = .disallowed
    window.setContentSize(NSSize(width: Self.settingsDefaultSize.width, height: Self.settingsDefaultSize.height))
    window.minSize = NSSize(width: 720, height: 540)
    // `.preference` is for the tab-strip style of Settings window. This one has a
    // sidebar, so it wants the unified titlebar System Settings uses.
    window.toolbarStyle = .unified
    window.titlebarSeparatorStyle = .automatic
    window.isReleasedWhenClosed = false

    // Order matters: naming the autosave first lets `setFrameUsingName` restore the
    // saved frame, and only a first run — where there is nothing to restore — gets
    // centred. Centring unconditionally is what threw the remembered size away.
    window.setFrameAutosaveName(Self.settingsFrameAutosaveName)
    if !window.setFrameUsingName(Self.settingsFrameAutosaveName) {
      window.center()
    }
    return window
  }

  private static let settingsFrameAutosaveName = "MenuCueSettingsWindow"
  private static let settingsDefaultSize = CGSize(width: 900, height: 680)

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
