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
/// Shared by the popover and the Dashboard pane: both are tab strips that should
/// answer the same sideways flick.
///
/// The direction alone is not enough to publish: two swipes the same way would look
/// identical and the second would not be observed, so each carries a sequence number.
final class SwipeRelay: ObservableObject {
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

/// Hosts SwiftUI content and turns a sideways flick over it into a tab change.
///
/// Two different AppKit opt-ins are involved, and using only the second is why
/// earlier attempts did nothing:
///
/// * `wantsScrollEventsForSwipeTracking(on:)` is the swipe-navigation one. When
///   "swipe between pages" is on — `NSEvent.isSwipeTrackingFromScrollEventsEnabled`,
///   which reflects the trackpad pane — a two-finger sideways flick is routed to the
///   view that asked for it, and is then driven through `NSEvent.trackSwipeEvent`.
/// * `wantsForwardedScrollEvents(for:)` is about *nested scrolling*: it hands on
///   scroll events an inner scroll view could not use. That is a different feature,
///   and on its own it never sees a swipe.
///
/// Both are declared: the first handles the flick when the system routes swipes, the
/// second plus the accumulator covers wheels and machines where page swiping is
/// turned off. Vertical scrolling is untouched in either path.
final class SwipeForwardingView: NSView {
  let relay = SwipeRelay()
  private var recognizer = SwipeRecognizer()
  /// Guards against `trackSwipeEvent` and the accumulator both firing for one flick.
  private var isTrackingSwipe = false

  /// Set `MENUCUE_SWIPE_LOG=1` to trace what actually arrives here.
  private static let isLogging = ProcessInfo.processInfo.environment["MENUCUE_SWIPE_LOG"] == "1"

  private func log(_ message: @autoclosure () -> String) {
    guard Self.isLogging else { return }
    FileHandle.standardError.write(Data("[swipe] \(message())\n".utf8))
  }

  override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
    axis == .horizontal
  }

  override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
    axis == .horizontal
  }

  override func scrollWheel(with event: NSEvent) {
    log(
      String(
        format: "dx=%.1f dy=%.1f phase=%d momentum=%d precise=%@ swipeTracking=%@",
        event.scrollingDeltaX, event.scrollingDeltaY, event.phase.rawValue,
        event.momentumPhase.rawValue, "\(event.hasPreciseScrollingDeltas)",
        "\(NSEvent.isSwipeTrackingFromScrollEventsEnabled)"))

    if beginSwipeTrackingIfPossible(with: event) { return }

    let outcome = recognizer.consume(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      phase: Self.phase(of: event),
      isPrecise: event.hasPreciseScrollingDeltas,
      now: event.timestamp
    )
    log("  accumulator -> \(outcome)")

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

  /// Hands a starting horizontal flick to AppKit's swipe tracker, which reports
  /// progress as a fraction of a page and tells us when the gesture committed.
  private func beginSwipeTrackingIfPossible(with event: NSEvent) -> Bool {
    guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
      event.phase == .began,
      !isTrackingSwipe,
      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    else { return false }

    isTrackingSwipe = true
    log("  trackSwipeEvent began")

    event.trackSwipeEvent(
      options: [.lockDirection],
      dampenAmountThresholdMin: -1,
      max: 1
    ) { [weak self] progress, phase, isComplete, stop in
      guard let self else {
        stop.pointee = true
        return
      }
      if phase == .ended || phase == .cancelled || isComplete {
        self.isTrackingSwipe = false
        // Half a page is the point of no return, matching how Safari's back/forward
        // swipe decides it has been committed.
        if phase == .ended, abs(progress) >= 0.5 {
          self.log("  trackSwipeEvent committed progress=\(progress)")
          // Dragging content left (negative progress) reveals the next tab.
          self.relay.send(progress < 0 ? 1 : -1)
        }
      }
    }
    return true
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

/// A `SwipeForwardingView` with the SwiftUI content as its only child, so the
/// container is an ancestor of every scroll view inside and can receive their
/// forwarded horizontal events.
final class SwipeForwardingController<Content: View>: NSViewController {
  private let hosting: NSHostingController<Content>

  var relay: SwipeRelay {
    containerView.relay
  }

  private var containerView: SwipeForwardingView {
    // `loadView` always installs this exact type.
    view as! SwipeForwardingView
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
    view = SwipeForwardingView(frame: .zero)
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
