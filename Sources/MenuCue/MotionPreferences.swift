import SwiftUI

enum MotionImportance {
  case primary
  case secondary
}

enum MotionNavigationStyle: Equatable {
  case spatial
  case crossfade
}

enum StatusClockMotion: Equatable {
  case push
  case none
}

struct MotionProfile {
  let quality: AnimationQuality
  let reducesMotion: Bool

  init(quality: AnimationQuality = .elegant, reducesMotion: Bool = false) {
    self.quality = quality
    self.reducesMotion = reducesMotion
  }

  var hoverAnimation: Animation? {
    guard !isMinimal else { return nil }
    return .easeOut(duration: quality == .full ? 0.14 : 0.10)
  }

  var pressAnimation: Animation? {
    guard !isMinimal else { return nil }
    if quality == .full {
      return .spring(response: 0.26, dampingFraction: 0.62)
    }
    return .easeOut(duration: 0.12)
  }

  var stateAnimation: Animation? {
    guard !isMinimal else { return nil }
    if quality == .full {
      return .snappy(duration: 0.22, extraBounce: 0.05)
    }
    return .easeOut(duration: 0.16)
  }

  var navigationAnimation: Animation? {
    if isMinimal { return .easeOut(duration: 0.08) }
    if quality == .full { return .snappy(duration: 0.18) }
    return .easeOut(duration: 0.12)
  }

  var barAnimation: Animation? {
    guard !isMinimal else { return nil }
    return .easeOut(duration: quality == .full ? 0.30 : 0.16)
  }

  var navigationStyle: MotionNavigationStyle {
    isMinimal ? .crossfade : .spatial
  }

  var usesMatchedGeometry: Bool {
    !isMinimal
  }

  var usesSymbolBounce: Bool {
    !reducesMotion && quality == .full
  }

  var continuousFrameInterval: TimeInterval? {
    guard !reducesMotion else { return nil }
    switch quality {
    case .full: return 1 / 20
    case .elegant: return 1 / 10
    case .minimal: return nil
    }
  }

  /// Switching clocks is a carousel, so the motion carries the scroll direction; a cross-fade
  /// would drop it. Only Reduce Motion and Minimal opt out, because this is one `CATransition`
  /// per scroll — nothing here rides on `continuousFrameInterval`.
  var statusClockMotion: StatusClockMotion {
    guard !reducesMotion, quality != .minimal else { return .none }
    return .push
  }

  /// Held at or under `StatusBarController.wheelSwitchCooldown`; a faster scroll than this
  /// would otherwise start the next push before the previous one lands.
  var statusClockTransitionDuration: TimeInterval {
    StatusBarController.wheelSwitchCooldown
  }

  func navigationTransition(forward: Bool) -> AnyTransition {
    guard navigationStyle == .spatial else { return .opacity }
    return .asymmetric(
      insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
      removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
    )
  }

  func revealTransition(edge: Edge) -> AnyTransition {
    guard navigationStyle == .spatial else { return .opacity }
    return .move(edge: edge).combined(with: .opacity)
  }

  func detailTransition(anchor: UnitPoint = .center) -> AnyTransition {
    guard navigationStyle == .spatial else { return .opacity }
    return .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
  }

  func valueAnimation(for importance: MotionImportance) -> Animation? {
    guard animatesNumeric(importance) else { return nil }
    return .easeOut(duration: quality == .full ? 0.30 : 0.16)
  }

  func animatesNumeric(_ importance: MotionImportance) -> Bool {
    guard !isMinimal else { return false }
    switch quality {
    case .full: return true
    case .elegant: return importance == .primary
    case .minimal: return false
    }
  }

  private var isMinimal: Bool {
    reducesMotion || quality == .minimal
  }
}

struct MotionAwareProgressIndicator: View {
  @Environment(\.menuCueMotion) private var motion
  var scale: CGFloat = 1

  var body: some View {
    Group {
      if motion.continuousFrameInterval != nil {
        ProgressView()
      } else {
        Image(systemName: "hourglass")
      }
    }
    .controlSize(.small)
    .scaleEffect(scale)
    .accessibilityLabel(L10n.string("Running"))
  }
}

private struct MenuCueMotionKey: EnvironmentKey {
  static let defaultValue = MotionProfile()
}

extension EnvironmentValues {
  var menuCueMotion: MotionProfile {
    get { self[MenuCueMotionKey.self] }
    set { self[MenuCueMotionKey.self] = newValue }
  }
}

extension View {
  func menuCueNumericTransition<Value: Equatable>(
    value: Value,
    importance: MotionImportance = .secondary
  ) -> some View {
    modifier(NumericMotionModifier(value: value, importance: importance))
  }

  func menuCueMatchedGeometryEffect<ID: Hashable>(
    id: ID,
    in namespace: Namespace.ID
  ) -> some View {
    modifier(MotionMatchedGeometryModifier(id: id, namespace: namespace))
  }
}

private struct NumericMotionModifier<Value: Equatable>: ViewModifier {
  @Environment(\.menuCueMotion) private var motion
  let value: Value
  let importance: MotionImportance

  @ViewBuilder
  func body(content: Content) -> some View {
    if motion.animatesNumeric(importance) {
      content
        .contentTransition(.numericText())
        .animation(motion.valueAnimation(for: importance), value: value)
    } else {
      content
    }
  }
}

private struct MotionMatchedGeometryModifier<ID: Hashable>: ViewModifier {
  @Environment(\.menuCueMotion) private var motion
  let id: ID
  let namespace: Namespace.ID

  @ViewBuilder
  func body(content: Content) -> some View {
    if motion.usesMatchedGeometry {
      content.matchedGeometryEffect(id: id, in: namespace)
    } else {
      content
    }
  }
}
