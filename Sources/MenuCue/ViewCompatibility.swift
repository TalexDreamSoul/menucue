import SwiftUI

extension View {
  @ViewBuilder
  func menuCueScrollBounceBehavior() -> some View {
    if #available(macOS 13.3, *) {
      scrollBounceBehavior(.basedOnSize)
    } else {
      self
    }
  }

  @ViewBuilder
  func menuCueFocusEffectDisabled() -> some View {
    if #available(macOS 14.0, *) {
      focusEffectDisabled()
    } else {
      self
    }
  }

  func menuCueSymbolBounce<Value: Equatable>(value: Value) -> some View {
    modifier(SymbolBounceModifier(value: value))
  }

  @ViewBuilder
  func menuCueHideSidebarToggle() -> some View {
    if #available(macOS 14.0, *) {
      toolbar(removing: .sidebarToggle)
    } else {
      self
    }
  }

  @ViewBuilder
  func menuCueHorizontalArrowNavigation(action: @escaping (Int) -> Void) -> some View {
    if #available(macOS 14.0, *) {
      modifier(HorizontalArrowNavigationModifier(action: action))
    } else {
      self
    }
  }

  @ViewBuilder
  func menuCueActivationKeys(action: @escaping () -> Void) -> some View {
    if #available(macOS 14.0, *) {
      modifier(ActivationKeyModifier(action: action))
    } else {
      self
    }
  }
}

private struct SymbolBounceModifier<Value: Equatable>: ViewModifier {
  @Environment(\.menuCueMotion) private var motion
  let value: Value

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *), motion.usesSymbolBounce {
      content.symbolEffect(.bounce, value: value)
    } else {
      content
    }
  }
}

@available(macOS 14.0, *)
private struct HorizontalArrowNavigationModifier: ViewModifier {
  let action: (Int) -> Void

  func body(content: Content) -> some View {
    content.onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
      guard PopoverTab.allowsNavigation(modifiers: press.modifiers) else { return .ignored }
      action(press.key == .leftArrow ? -1 : 1)
      return .handled
    }
  }
}

@available(macOS 14.0, *)
private struct ActivationKeyModifier: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .onKeyPress(.return) {
        action()
        return .handled
      }
      .onKeyPress(.space) {
        action()
        return .handled
      }
  }
}
