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
    case .began:
      // With "swipe between pages" on, macOS does not send a stream to accumulate.
      // It collapses the whole flick into a *single* event: phase `.began`, no
      // `.changed`, no `.ended`, and a normalized ±1 horizontal delta rather than a
      // pixel distance. Measured on a real trackpad — every event logged `phase=1
      // dx=±1.0`. Resetting and passing here, as an ordinary gesture start, is why
      // the accumulator could never reach its threshold.
      accumulated = 0
      isArmed = true
      if isDiscreteSwipe(deltaX: deltaX, deltaY: deltaY) {
        guard now - lastCoarseFire > coarseInterval else { return .consume }
        lastCoarseFire = now
        isArmed = false
        return .navigate(direction(for: deltaX))
      }
      return .pass
    case .ended:
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

  /// A whole flick delivered as one normalized event, rather than the start of a
  /// stream to accumulate.
  ///
  /// The tell is the magnitude: a page swipe arrives as ±1, while a real two-finger
  /// scroll opens with deltas near zero and only builds up over later `.changed`
  /// events. Requiring the vertical component to be negligible keeps a diagonal
  /// scroll from being mistaken for one.
  private func isDiscreteSwipe(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
    abs(deltaX) >= 1 && abs(deltaY) < 0.5
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
/// Both are declared, because either can be what causes the events to arrive here.
/// The judgement itself is always the accumulator.
///
/// `NSEvent.trackSwipeEvent` was tried on top of this and removed: once handed a
/// gesture it swallows every event of that gesture, and if it never reports a commit
/// — which is what a real flick did — the swipe silently does nothing. Deferring to
/// it traded a tested accumulator for an untestable black box.
final class SwipeForwardingView: NSView {
  let relay: SwipeRelay
  private var recognizer = SwipeRecognizer()

  init(frame frameRect: NSRect, relay: SwipeRelay = SwipeRelay()) {
    self.relay = relay
    super.init(frame: frameRect)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

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

/// Hosted content that pins its own appearance and therefore has to be told when the
/// app's appearance changes, rather than inheriting it from an ancestor.
protocol AppearanceForwarding: AnyObject {
  func applyAppearance(_ appearance: NSAppearance?)
}

/// A `SwipeForwardingView` with the SwiftUI content as its only child, so the
/// container is an ancestor of every scroll view inside and can receive their
/// forwarded horizontal events.
final class SwipeForwardingController<Content: View>: NSViewController, AppearanceForwarding {
  private let hosting: NSHostingController<Content>
  private let swipeRelay: SwipeRelay

  var relay: SwipeRelay {
    swipeRelay
  }

  private var containerView: SwipeForwardingView {
    // `loadView` always installs this exact type.
    view as! SwipeForwardingView
  }

  init(rootView: Content, relay: SwipeRelay = SwipeRelay()) {
    self.hosting = NSHostingController(rootView: rootView)
    self.swipeRelay = relay
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func loadView() {
    view = SwipeForwardingView(frame: .zero, relay: swipeRelay)
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

  /// Assigning an appearance re-runs the appearance walk over the whole hosted tree even
  /// when the value is unchanged, and this runs once a second — so compare first.
  func applyAppearance(_ appearance: NSAppearance?) {
    if view.appearance !== appearance {
      view.appearance = appearance
    }
    if hosting.view.appearance !== appearance {
      hosting.view.appearance = appearance
    }
  }
}
