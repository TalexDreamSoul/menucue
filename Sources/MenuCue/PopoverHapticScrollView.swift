import SwiftUI

private struct PopoverScrollContentBottomKey: PreferenceKey {
  static let defaultValue: CGFloat = .infinity

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

/// A popover scroll container that confirms a real arrival at the content bottom once.
/// Short content and initial layout never generate feedback.
struct PopoverHapticScrollView<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @State private var viewportHeight: CGFloat = 0
  @State private var hasScrollableContent = false
  @State private var isAtBottom = false

  var body: some View {
    ScrollView {
      content()
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: PopoverScrollContentBottomKey.self,
              value: proxy.frame(in: .named("popover-scroll")).maxY)
          })
        .padding(.horizontal, PopoverMetrics.contentPadding)
        .padding(.vertical, 2)
    }
    .coordinateSpace(name: "popover-scroll")
    .background(
      GeometryReader { proxy in
        Color.clear
          .onAppear { viewportHeight = proxy.size.height }
          .onChange(of: proxy.size.height) { viewportHeight = $0 }
      })
    .onPreferenceChange(PopoverScrollContentBottomKey.self, perform: updateScrollPosition)
    .menuCueScrollBounceBehavior()
  }

  private func updateScrollPosition(contentBottom: CGFloat) {
    guard viewportHeight > 0 else { return }
    let bottomTolerance: CGFloat = 1
    if contentBottom > viewportHeight + bottomTolerance {
      hasScrollableContent = true
      isAtBottom = false
      return
    }
    guard hasScrollableContent, !isAtBottom else { return }
    isAtBottom = true
    MenuCueHaptics.performAlignment()
  }
}
