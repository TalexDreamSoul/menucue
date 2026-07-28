import AppKit
import SwiftUI

/// Turns a horizontal trackpad swipe into a tab change.
///
/// A background `NSView` would never see these events — the popover's `ScrollView`
/// sits above it and consumes `scrollWheel` first — so this installs a local monitor
/// instead and scopes it to the popover's own window. Vertical scrolling is left
/// entirely alone: an event only counts when its horizontal component clearly
/// dominates, which is what separates a deliberate sideways flick from the slight
/// sideways drift in an ordinary vertical scroll.
struct HorizontalSwipeNavigator: NSViewRepresentable {
  /// `+1` moves to the next tab, `-1` to the previous one.
  let onSwipe: (Int) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onSwipe = onSwipe
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onSwipe: onSwipe)
  }

  final class Coordinator {
    var onSwipe: (Int) -> Void
    private weak var view: NSView?
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    /// One tab per gesture: without this a long flick would race through every tab.
    private var isArmed = true
    /// A non-precise wheel has no gesture phases, so it is rate-limited instead.
    private var lastCoarseSwipe = Date.distantPast

    /// Far enough that it cannot be reached by the sideways wobble of a vertical
    /// scroll, close enough that a deliberate flick lands on the first try.
    private static let threshold: CGFloat = 42
    private static let coarseInterval: TimeInterval = 0.35

    init(onSwipe: @escaping (Int) -> Void) {
      self.onSwipe = onSwipe
    }

    func attach(to view: NSView) {
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    func detach() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    deinit {
      detach()
    }

    /// Returns `nil` to swallow the event, or the event to let it through.
    private func handle(_ event: NSEvent) -> NSEvent? {
      // The monitor is app-wide; anything outside the popover is none of our business.
      guard let window = view?.window, event.window === window else { return event }

      let dx = event.scrollingDeltaX
      let dy = event.scrollingDeltaY

      guard event.hasPreciseScrollingDeltas else {
        // Mouse wheels and older devices: no phases, so debounce by time.
        guard abs(dx) > abs(dy), abs(dx) > 1 else { return event }
        guard Date().timeIntervalSince(lastCoarseSwipe) > Self.coarseInterval else { return nil }
        lastCoarseSwipe = Date()
        onSwipe(dx < 0 ? 1 : -1)
        return nil
      }

      switch event.phase {
      case .began, .mayBegin:
        accumulated = 0
        isArmed = true
        return event
      case .ended, .cancelled:
        accumulated = 0
        isArmed = true
        return event
      default:
        break
      }

      // Momentum is the tail of a gesture that already fired; letting it through
      // would trigger a second tab change after the fingers have lifted.
      guard event.momentumPhase == [] else { return isArmed ? event : nil }
      guard isArmed else { return nil }

      // A vertical scroll that drifts sideways must keep scrolling vertically.
      guard abs(dx) > abs(dy) * 1.5 else { return event }

      accumulated += dx
      guard abs(accumulated) >= Self.threshold else { return nil }

      isArmed = false
      // Natural scrolling: fingers moving left push content left, revealing the tab
      // to the right — the same direction a paged scroll view would travel.
      onSwipe(accumulated < 0 ? 1 : -1)
      accumulated = 0
      return nil
    }
  }
}
