import AppKit

/// The floating panel a trackpad gesture uses to report what it just did. It follows the
/// pointer rather than the app, because a gesture can fire while another app is frontmost.
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

  private func position(_ panel: NSPanel) {
    let point = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
    let desiredOrigin = NSPoint(x: point.x - panel.frame.width / 2, y: point.y + 22)
    let x = min(max(desiredOrigin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - panel.frame.width)
    let y = min(max(desiredOrigin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - panel.frame.height)
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }
}
