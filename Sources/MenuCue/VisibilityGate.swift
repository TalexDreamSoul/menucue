import Combine
import SwiftUI

/// Starts work when a surface comes on screen and stops it when the surface goes away.
///
/// Every retained surface in this app needs one. `NSPopover` keeps its content after
/// closing, and both windows are `isReleasedWhenClosed = false` — so SwiftUI's
/// `onDisappear` is a fallback rather than a guarantee, and anything acquired from
/// `onAppear` would otherwise stay acquired for the rest of the session: a sampling
/// timer, the trackpad's 30 Hz live preview, a `pmset` poll.
///
/// Transitions are idempotent in both directions, so a repeated visibility change
/// cannot leave a service retained twice or released twice.
@MainActor
final class VisibilityGate: ObservableObject {
  private var visibilityCancellable: AnyCancellable?
  private var stopAction: (() -> Void)?
  private(set) var isActive = false

  func connect(
    to visibility: AnyPublisher<Bool, Never>,
    onStart: @escaping () -> Void,
    onStop: @escaping () -> Void
  ) {
    guard visibilityCancellable == nil else { return }
    stopAction = onStop
    visibilityCancellable = visibility
      .removeDuplicates()
      .sink { [weak self] isVisible in
        self?.update(isVisible: isVisible, onStart: onStart, onStop: onStop)
      }
  }

  func connect(
    to presentation: PopoverPresentationState,
    onStart: @escaping () -> Void,
    onStop: @escaping () -> Void
  ) {
    connect(to: presentation.$isVisible.eraseToAnyPublisher(), onStart: onStart, onStop: onStop)
  }

  func disconnect() {
    visibilityCancellable = nil
    guard isActive else {
      stopAction = nil
      return
    }
    isActive = false
    let stop = stopAction
    stopAction = nil
    stop?()
  }

  private func update(
    isVisible: Bool,
    onStart: () -> Void,
    onStop: () -> Void
  ) {
    guard isVisible != isActive else { return }
    isActive = isVisible
    if isVisible {
      onStart()
    } else {
      onStop()
    }
  }
}
