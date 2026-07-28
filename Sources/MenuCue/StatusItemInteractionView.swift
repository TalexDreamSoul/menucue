import AppKit

final class StatusItemInteractionView: NSView {
    var onPrimaryClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.highlight(true)
    }

    override func mouseUp(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.highlight(false)
        if event.modifierFlags.contains(.control) {
            onSecondaryClick?()
        } else {
            onPrimaryClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.highlight(true)
    }

    override func rightMouseUp(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.highlight(false)
        onSecondaryClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}
