import AppKit
import Combine
import SwiftUI

/// Decides when a stream of scroll deltas amounts to a deliberate sideways flick.
///
/// A plain value type with no AppKit dependency, so the decision can be unit-tested —
/// the event plumbing around it cannot be exercised from a test.
struct SwipeRecognizer {
  /// Far enough not to be reached by the sideways wobble in a vertical scroll,
  /// close enough that one flick lands.
  var threshold: CGFloat = 28
  /// How much the horizontal component must beat the vertical one.
  var dominance: CGFloat = 1.2
  /// Debounce for devices that report no gesture phases, such as a mouse wheel.
  var coarseInterval: TimeInterval = 0.35

  private var accumulated: CGFloat = 0
  /// One tab per gesture: a long flick must not race through every tab.
  private var isArmed = true
  private var lastCoarseFire: TimeInterval = -.greatestFiniteMagnitude

  enum Phase {
    case began
    case changed
    case ended
    /// Inertia after the fingers lift. The gesture has already been judged.
    case momentum
    /// A device that reports no phases at all.
    case none
  }

  enum Outcome: Equatable {
    /// Move by this many tabs, and swallow the event.
    case navigate(Int)
    /// Part of a gesture being tracked; swallow so it does not scroll anything.
    case consume
    /// Not ours — let it through to whatever wanted to scroll.
    case pass
  }

  mutating func consume(
    deltaX: CGFloat,
    deltaY: CGFloat,
    phase: Phase,
    isPrecise: Bool,
    now: TimeInterval
  ) -> Outcome {
    guard isPrecise else {
      // Wheels and older devices: no phases, so rate-limit instead of accumulating.
      guard abs(deltaX) > abs(deltaY), abs(deltaX) > 1 else { return .pass }
      guard now - lastCoarseFire > coarseInterval else { return .consume }
      lastCoarseFire = now
      return .navigate(direction(for: deltaX))
    }

    switch phase {
    case .began, .ended:
      accumulated = 0
      isArmed = true
      return .pass
    case .momentum:
      // The gesture already fired; inertia must not fire it again.
      return isArmed ? .pass : .consume
    case .changed, .none:
      break
    }

    guard isArmed else { return .consume }
    // A vertical scroll that drifts sideways must keep scrolling vertically.
    guard abs(deltaX) > abs(deltaY) * dominance else { return .pass }

    accumulated += deltaX
    guard abs(accumulated) >= threshold else { return .consume }

    isArmed = false
    let step = direction(for: accumulated)
    accumulated = 0
    return .navigate(step)
  }

  /// Natural scrolling: fingers moving left push content left, revealing the tab to
  /// the right — the same direction a paged scroll view would travel.
  private func direction(for delta: CGFloat) -> Int {
    delta < 0 ? 1 : -1
  }
}

/// Carries a recognized swipe from the AppKit container down into SwiftUI.
///
/// The direction alone is not enough to publish: two swipes the same way would look
/// identical and the second would not be observed, so each carries a sequence number.
final class PopoverSwipeRelay: ObservableObject {
  struct Command: Equatable {
    let direction: Int
    let sequence: Int
  }

  @Published private(set) var command: Command?
  private var sequence = 0

  func send(_ direction: Int) {
    sequence += 1
    command = Command(direction: direction, sequence: sequence)
  }
}

/// Hosts the popover's SwiftUI content and turns a sideways flick into a tab change.
///
/// This is the documented AppKit route for exactly this problem: an `NSScrollView`
/// that cannot use a scroll event on a given axis walks up the responder chain for a
/// view that opted into that axis and forwards `scrollWheel(with:)` to it. A local
/// event monitor was tried first and never fired reliably; forwarding puts the
/// decision where AppKit already routes it, and leaves vertical scrolling untouched
/// because the scroll view consumes that itself before any forwarding happens.
final class PopoverSwipeContainerView: NSView {
  let relay = PopoverSwipeRelay()
  private var recognizer = SwipeRecognizer()

  /// Opting into the horizontal axis is what makes `NSScrollView` forward here.
  override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
    axis == .horizontal
  }

  override func scrollWheel(with event: NSEvent) {
    let outcome = recognizer.consume(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      phase: Self.phase(of: event),
      isPrecise: event.hasPreciseScrollingDeltas,
      now: event.timestamp
    )

    switch outcome {
    case let .navigate(step):
      relay.send(step)
    case .consume:
      break
    case .pass:
      // Nothing here wanted it; let the rest of the chain try.
      super.scrollWheel(with: event)
    }
  }

  private static func phase(of event: NSEvent) -> SwipeRecognizer.Phase {
    if event.momentumPhase != [] { return .momentum }
    switch event.phase {
    case .began, .mayBegin: return .began
    case .ended, .cancelled: return .ended
    case .changed: return .changed
    default: return .none
    }
  }
}

/// View controller for the popover: a `PopoverSwipeContainerView` with the SwiftUI
/// content as its only child, so the container is an ancestor of every scroll view
/// inside and can receive their forwarded horizontal events.
final class PopoverContainerController<Content: View>: NSViewController {
  private let hosting: NSHostingController<Content>

  var relay: PopoverSwipeRelay {
    containerView.relay
  }

  private var containerView: PopoverSwipeContainerView {
    // `loadView` always installs this exact type.
    view as! PopoverSwipeContainerView
  }

  init(rootView: Content) {
    self.hosting = NSHostingController(rootView: rootView)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func loadView() {
    view = PopoverSwipeContainerView(frame: .zero)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(hosting)
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  func applyAppearance(_ appearance: NSAppearance?) {
    view.appearance = appearance
    hosting.view.appearance = appearance
  }
}
