import AppKit

/// Where the panel sits on a given screen. Kept apart from the panel itself because the
/// arithmetic is the part worth testing, and a test cannot conjure a second display.
enum TrackpadFeedbackHUDLayout {
  static let panelSize = CGSize(width: 236, height: 64)
  /// Matches the radius AppKit gives its own HUD panels; a smaller one reads as a plain
  /// rectangle at this size.
  static let cornerRadius: CGFloat = 17
  static let padding: CGFloat = 16
  static let iconSize: CGFloat = 22

  /// Height above the usable area the panel floats at, in the band the system volume
  /// bezel uses. Measured from `visibleFrame`, so a Dock along the bottom pushes the
  /// panel up with it instead of hiding behind it.
  static let bottomInset: CGFloat = 96

  /// Bottom-centred inside `visibleFrame`, in the same global coordinates AppKit hands
  /// out — a screen left of the main one has a negative origin, and the result follows it
  /// there. `visibleFrame` already excludes the menu bar and the Dock on whichever side
  /// it sits, so no edge needs naming here.
  static func origin(panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
    // A panel that cannot fit is pinned to the near corner rather than centred out of
    // view; clamping to a negative span would otherwise put it off-screen.
    let furthestX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
    let furthestY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
    return CGPoint(
      x: min(max(visibleFrame.midX - panelSize.width / 2, visibleFrame.minX), furthestX),
      y: min(max(visibleFrame.minY + bottomInset, visibleFrame.minY), furthestY)
    )
  }

  /// With a level to draw, the readout becomes a labelled bar and the icon takes the left
  /// column. Without one it is a single centred sentence, because there is nothing to
  /// align a column to.
  static func contentFrames(showingLevel: Bool) -> (icon: CGRect, label: CGRect, bar: CGRect) {
    let width = panelSize.width
    let height = panelSize.height
    guard showingLevel else {
      return (
        icon: .zero,
        label: CGRect(x: padding, y: 14, width: width - padding * 2, height: height - 28),
        bar: .zero
      )
    }
    let contentX = padding + iconSize + 12
    let contentWidth = width - contentX - padding
    return (
      icon: CGRect(x: padding, y: (height - iconSize) / 2, width: iconSize, height: iconSize),
      label: CGRect(x: contentX, y: 33, width: contentWidth, height: 18),
      bar: CGRect(x: contentX, y: 21, width: contentWidth, height: 6)
    )
  }
}

/// The filled track under the readout. Drawn rather than assembled from an NSProgressIndicator
/// so it can be repainted dozens of times a second without the animation an indicator insists
/// on running between two values.
final class TrackpadFeedbackLevelBar: NSView {
  var level: Double = 0 {
    didSet {
      guard level != oldValue else { return }
      needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.labelColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

    let filledWidth = bounds.width * CGFloat(min(max(level, 0), 1))
    guard filledWidth > 0 else { return }
    // A fill narrower than the track is round is drawn as a dot, so the rounded rect never
    // renders wider than the value it stands for.
    let filled = NSRect(x: 0, y: 0, width: max(filledWidth, bounds.height), height: bounds.height)
    NSColor.labelColor.setFill()
    NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
  }
}

/// The floating panel a trackpad gesture uses to report what it just did. It sits at the
/// bottom of whichever screen the pointer is on, rather than following the pointer, because
/// a gesture can fire while another app is frontmost and a readout that moves is one the
/// eye has to hunt for.
final class TrackpadFeedbackHUD {
  private static let visibleDuration: TimeInterval = 1.6
  private static let fadeDuration: TimeInterval = 0.18

  private var panel: NSPanel?
  private var label: NSTextField?
  private var levelBar: TrackpadFeedbackLevelBar?
  private var iconView: NSImageView?
  private var dismissWorkItem: DispatchWorkItem?

  deinit {
    dismissWorkItem?.cancel()
    panel?.orderOut(nil)
  }

  /// `level` is 0...1 for an adjustment that landed somewhere on a scale. It gets a bar,
  /// because a continuous gesture repaints this several times a second and a bar is
  /// readable at that rate where a percentage is not.
  func show(_ message: String, isFailure: Bool, level: Double? = nil, symbolName: String? = nil) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let panel = self.panel ?? self.makePanel()
      guard let label = self.label, let levelBar = self.levelBar, let iconView = self.iconView
      else {
        return
      }

      let frames = TrackpadFeedbackHUDLayout.contentFrames(showingLevel: level != nil)
      label.stringValue = message
      label.textColor = isFailure ? .systemRed : .labelColor
      label.alignment = level == nil ? .center : .left
      label.frame = frames.label

      if let level {
        levelBar.level = min(max(level, 0), 1)
        levelBar.frame = frames.bar
      }
      levelBar.isHidden = level == nil

      iconView.image = symbolName.flatMap {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)
      }
      iconView.contentTintColor = isFailure ? .systemRed : .labelColor
      iconView.frame = frames.icon
      iconView.isHidden = iconView.image == nil || level == nil

      self.position(panel)
      // Only the first appearance fades in. A continuous gesture calls this many times a
      // second, and restarting the animation on each one is a strobe.
      if !panel.isVisible {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
          context.duration = Self.fadeDuration
          panel.animator().alphaValue = 1
        }
      } else {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
      }
      self.scheduleDismiss(panel)
    }
  }

  private func scheduleDismiss(_ panel: NSPanel) {
    dismissWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak panel] in
      guard let panel else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.fadeDuration
        panel.animator().alphaValue = 0
      } completionHandler: {
        // A step that arrived while this was fading takes the panel back to full opacity,
        // and must not be hidden by the fade it interrupted.
        if panel.alphaValue == 0 { panel.orderOut(nil) }
      }
    }
    dismissWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: workItem)
  }

  private func makePanel() -> NSPanel {
    let size = TrackpadFeedbackHUDLayout.panelSize
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    panel.isReleasedWhenClosed = false

    let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effectView.material = .hudWindow
    effectView.blendingMode = .behindWindow
    effectView.state = .active
    effectView.autoresizingMask = [.width, .height]
    // Without this the borderless panel is a hard-cornered rectangle, which is the one
    // shape macOS never uses for a floating readout.
    effectView.wantsLayer = true
    effectView.layer?.cornerRadius = TrackpadFeedbackHUDLayout.cornerRadius
    effectView.layer?.masksToBounds = true
    if #available(macOS 14.0, *) {
      effectView.layer?.cornerCurve = .continuous
    }
    // The layer radius clips only the view's own drawing. The behind-window blur is
    // composited by the window server from the effect view's mask, so without one the
    // backdrop keeps square corners that read as white spurs on a light desktop.
    let maskRadius = TrackpadFeedbackHUDLayout.cornerRadius
    let maskEdge = maskRadius * 2 + 1
    let mask = NSImage(
      size: NSSize(width: maskEdge, height: maskEdge),
      flipped: false
    ) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: maskRadius, yRadius: maskRadius).fill()
      return true
    }
    mask.capInsets = NSEdgeInsets(
      top: maskRadius, left: maskRadius, bottom: maskRadius, right: maskRadius)
    mask.resizingMode = .stretch
    effectView.maskImage = mask

    let frames = TrackpadFeedbackHUDLayout.contentFrames(showingLevel: false)

    let iconView = NSImageView(frame: .zero)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.isHidden = true
    effectView.addSubview(iconView)

    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.frame = frames.label
    effectView.addSubview(label)

    let levelBar = TrackpadFeedbackLevelBar(frame: .zero)
    levelBar.isHidden = true
    effectView.addSubview(levelBar)

    panel.contentView = effectView
    self.panel = panel
    self.label = label
    self.levelBar = levelBar
    self.iconView = iconView
    return panel
  }

  /// The pointer picks the screen and nothing else. Recomputed on every show, so a Dock
  /// that moved or a display that was unplugged needs no invalidation of its own.
  private func position(_ panel: NSPanel) {
    let point = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    guard let screen else { return }
    panel.setFrameOrigin(
      TrackpadFeedbackHUDLayout.origin(panelSize: panel.frame.size, in: screen.visibleFrame)
    )
  }
}
