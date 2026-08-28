import CoreGraphics
import Foundation

/// The two Quartz calls that detach the pointer from trackpad movement, behind a seam so
/// the freeze bookkeeping can be exercised without moving the real cursor.
protocol PointerFreezing: AnyObject {
  func freeze()
  func unfreeze()
}

/// Neither call needs Accessibility: detaching the cursor is a Quartz display service, not
/// an input tap, so freezing the pointer adds no permission to the ones already asked for.
final class SystemPointerFreezer: PointerFreezing {
  // Touched only inside the main-queue block, which is also where the Quartz calls run.
  private var isFrozen = false
  private var restorePosition: CGPoint?

  func freeze() {
    performOnMain { [self] in
      guard !isFrozen else { return }
      isFrozen = true
      restorePosition = CGEvent(source: nil)?.location
      CGAssociateMouseAndMouseCursorPosition(0)
    }
  }

  func unfreeze() {
    performOnMain { [self] in
      guard isFrozen else { return }
      isFrozen = false
      // Warping before reconnecting pins the cursor where it was left, instead of letting
      // it reappear wherever the detached hardware position drifted to.
      if let restorePosition { CGWarpMouseCursorPosition(restorePosition) }
      restorePosition = nil
      CGAssociateMouseAndMouseCursorPosition(1)
    }
  }

  /// Always asynchronous, never synchronous-when-already-on-main: main-queue order is what
  /// keeps a freeze and an unfreeze decided on two different threads from swapping places.
  private func performOnMain(_ operation: @escaping () -> Void) {
    DispatchQueue.main.async(execute: operation)
  }
}

/// Holds the pointer still for one continuous-adjustment session, because the fingers
/// sliding a volume rule along the edge are the same fingers the cursor follows.
///
/// Freezing is the easy half. Every way a session can end has to reach `release()` —
/// lift-off, a device or engine reset, the service stopping, or frames simply never
/// arriving again — or the user is left with a cursor that cannot move.
///
/// The freezer and the watchdog scheduler are both called with the state lock held, so
/// neither may reach back into the coordinator synchronously: the lock is not recursive, and
/// a scheduler that ran its body inline would deadlock on the next line.
final class TrackpadPointerFreezeCoordinator {
  /// No frame from the owning device for this long means the lift-off frame is not coming.
  static let stallTimeout: TimeInterval = 1.5

  private let freezer: PointerFreezing
  private let now: () -> TimeInterval
  private let scheduleWatchdog: (TimeInterval, @escaping () -> Void) -> Void

  private let lock = NSLock()
  private var frozenDeviceID: UInt64?
  private var lastFrameAt: TimeInterval = 0
  private var hasPendingWatchdog = false

  init(
    freezer: PointerFreezing,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    scheduleWatchdog: @escaping (TimeInterval, @escaping () -> Void) -> Void
  ) {
    self.freezer = freezer
    self.now = now
    self.scheduleWatchdog = scheduleWatchdog
  }

  var isFrozen: Bool {
    lock.lock()
    defer { lock.unlock() }
    return frozenDeviceID != nil
  }

  /// A continuous step landed, so this device owns the pointer until its contacts end.
  /// Waiting for the first step rather than for the corridor is what keeps an ordinary
  /// two-finger scroll from freezing anything. A second device taking over does not
  /// re-freeze what is already frozen.
  func beginContinuousAdjustment(deviceID: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    lastFrameAt = now()
    let wasFrozen = frozenDeviceID != nil
    frozenDeviceID = deviceID
    if !wasFrozen { freezer.freeze() }
    armWatchdogLocked()
  }

  /// Every frame from the owning device refreshes the stall deadline until its contacts are
  /// gone, which releases the pointer at once — ahead of the momentum drain, which goes on
  /// swallowing scroll events for a moment afterwards.
  func observeFrame(deviceID: UInt64, hasContacts: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard frozenDeviceID == deviceID else { return }
    guard hasContacts else {
      unfreezeLocked()
      return
    }
    lastFrameAt = now()
  }

  /// Release for every path that abandons a session without a final frame, whichever device
  /// owns it. Idempotent, so a path that is covered twice costs nothing.
  func release() {
    lock.lock()
    defer { lock.unlock() }
    unfreezeLocked()
  }

  private func unfreezeLocked() {
    guard frozenDeviceID != nil else { return }
    frozenDeviceID = nil
    freezer.unfreeze()
  }

  /// Armed for what is left of the deadline rather than a fresh full timeout, so a session
  /// that keeps sending frames until it stalls is still released 1.5s after its last one.
  ///
  /// A release deliberately does not clear `hasPendingWatchdog`: the scheduled block cannot
  /// be cancelled, so the next session inherits it instead of adding a second one, and the
  /// inherited block re-arms itself against that session's own last frame.
  private func armWatchdogLocked() {
    guard !hasPendingWatchdog else { return }
    hasPendingWatchdog = true
    scheduleWatchdog(Self.stallTimeout - (now() - lastFrameAt)) { [weak self] in
      self?.handleWatchdogFired()
    }
  }

  private func handleWatchdogFired() {
    lock.lock()
    defer { lock.unlock() }
    hasPendingWatchdog = false
    guard frozenDeviceID != nil else { return }
    guard now() - lastFrameAt >= Self.stallTimeout else {
      armWatchdogLocked()
      return
    }
    unfreezeLocked()
  }
}
