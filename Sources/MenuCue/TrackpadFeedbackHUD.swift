import AppKit

/// Where the panel sits on a given screen. Kept apart from the panel itself because the
/// arithmetic is the part worth testing, and a test cannot conjure a second display.
enum TrackpadFeedbackHUDLayout {
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
}

/// The floating panel a trackpad gesture uses to report what it just did. It sits at the
/// bottom of whichever screen the pointer is on, rather than following the pointer, because
/// a gesture can fire while another app is frontmost and a readout that moves is one the
/// eye has to hunt for.
final class TrackpadFeedbackHUD {
  private var panel: NSPanel?
  private var label: NSTextField?
  private var dismissWorkItem: DispatchWorkItem?

  deinit {
    dismissWorkItem?.cancel()
    panel?.orderOut(nil)
  }

  func show(_ message: String, isFailure: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let panel = self.panel ?? self.makePanel()
      guard let label = self.label else { return }
      label.stringValue = message
      label.textColor = isFailure ? .systemRed : .labelColor
      self.position(panel)
      panel.orderFrontRegardless()
      self.dismissWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
      self.dismissWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 48),
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

    let effectView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
    effectView.material = .hudWindow
    effectView.blendingMode = .withinWindow
    effectView.state = .active
    effectView.autoresizingMask = [.width, .height]

    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.frame = NSRect(x: 14, y: 8, width: 252, height: 32)
    label.autoresizingMask = [.width, .height]
    effectView.addSubview(label)
    panel.contentView = effectView
    self.panel = panel
    self.label = label
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
